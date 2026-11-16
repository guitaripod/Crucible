#define _GNU_SOURCE
#define CURL_DISABLE_TYPECHECK
#include <curl/curl.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

typedef CURLMcode (*setopt_fn)(CURLM *, CURLMoption, ...);
typedef CURLMcode (*cleanup_fn)(CURLM *);
typedef CURLMcode (*assign_fn)(CURLM *, curl_socket_t, void *);

/** What one multi handle's owner (URLSession) set as its socket callback and data, and what libcurl last wanted for each
 * socket of the handle. */
typedef struct socket_relay {
    CURLM *multi;
    curl_socket_callback callback;
    void *data;
    unsigned char *wants;
    size_t capacity;
    struct socket_relay *next;
} socket_relay;

static pthread_mutex_t relays_lock = PTHREAD_MUTEX_INITIALIZER;
static socket_relay *relays;

static socket_relay *relay_for(CURLM *multi) {
    pthread_mutex_lock(&relays_lock);
    socket_relay *relay = relays;
    while (relay && relay->multi != multi) relay = relay->next;
    if (!relay) {
        relay = calloc(1, sizeof(*relay));
        if (relay) {
            relay->multi = multi;
            relay->next = relays;
            relays = relay;
        }
    }
    pthread_mutex_unlock(&relays_lock);
    return relay;
}

static void relay_forget(CURLM *multi) {
    pthread_mutex_lock(&relays_lock);
    socket_relay **link = &relays;
    while (*link && (*link)->multi != multi) link = &(*link)->next;
    socket_relay *gone = *link;
    if (gone) *link = gone->next;
    pthread_mutex_unlock(&relays_lock);
    if (gone) {
        free(gone->wants);
        free(gone);
    }
}

static int last_wanted(socket_relay *relay, curl_socket_t socket) {
    return socket >= 0 && (size_t) socket < relay->capacity ? relay->wants[socket] : CURL_POLL_NONE;
}

static void remember(socket_relay *relay, curl_socket_t socket, int what) {
    if (socket < 0) return;
    if ((size_t) socket >= relay->capacity) {
        size_t capacity = relay->capacity ? relay->capacity : 256;
        while (capacity <= (size_t) socket) capacity *= 2;
        unsigned char *grown = realloc(relay->wants, capacity);
        if (!grown) return;
        memset(grown + relay->capacity, 0, capacity - relay->capacity);
        relay->wants = grown;
        relay->capacity = capacity;
    }
    relay->wants[socket] = (unsigned char) (what == CURL_POLL_REMOVE ? CURL_POLL_NONE : what);
}

/** URLSession's socket callback, between libcurl and swift-corelibs-foundation. libcurl names, per socket, whether it
 * waits to read, to write or both, and URLSession keeps a libdispatch read and write source for the socket, but it only
 * ever adds them: once libcurl has sent a request and only waits to read, the write source stays, fires as fast as the
 * socket is writable (always) and hands libcurl an action it has no use for. For a short request that lasts until the
 * socket goes; for one that stays open (the server's event stream, a long poll) a core spins at full load for as long as
 * the app runs. So when libcurl stops wanting one of the two, URLSession's sources for the socket are taken down and only
 * the wanted one is made again, as if libcurl had removed the socket and added it back. Runs on the multi handle's serial
 * queue, so a relay's table is only touched from one thread at a time. */
static int relay_socket(CURL *easy, curl_socket_t socket, int what, void *client, void *socketp) {
    static assign_fn assign;
    if (!assign) assign = (assign_fn) dlsym(RTLD_NEXT, "curl_multi_assign");
    socket_relay *relay = client;
    int before = last_wanted(relay, socket);
    int dropped = what != CURL_POLL_REMOVE && (before & CURL_POLL_INOUT & ~what) != 0;
    remember(relay, socket, what);
    if (!dropped || !assign) return relay->callback(easy, socket, what, relay->data, socketp);
    relay->callback(easy, socket, CURL_POLL_REMOVE, relay->data, socketp);
    assign(relay->multi, socket, NULL);
    return relay->callback(easy, socket, what, relay->data, NULL);
}

/** libcurl's own function, standing in for it (the executable's symbol wins over the library's) to put `relay_socket`
 * between libcurl and the socket callback a multi handle's owner sets, whichever of the callback and its data comes first. */
CURLMcode curl_multi_setopt(CURLM *multi, CURLMoption option, ...) {
    static setopt_fn forward;
    if (!forward) forward = (setopt_fn) dlsym(RTLD_NEXT, "curl_multi_setopt");
    if (!forward) return CURLM_INTERNAL_ERROR;
    va_list arguments;
    va_start(arguments, option);
    CURLMcode result;
    socket_relay *relay = option == CURLMOPT_SOCKETFUNCTION || option == CURLMOPT_SOCKETDATA ? relay_for(multi) : NULL;
    if (relay) {
        if (option == CURLMOPT_SOCKETFUNCTION) relay->callback = va_arg(arguments, curl_socket_callback);
        else relay->data = va_arg(arguments, void *);
        if (relay->callback) {
            result = forward(multi, CURLMOPT_SOCKETDATA, relay);
            if (result == CURLM_OK) result = forward(multi, CURLMOPT_SOCKETFUNCTION, relay_socket);
        } else {
            result = forward(multi, CURLMOPT_SOCKETDATA, relay->data);
            if (result == CURLM_OK) result = forward(multi, CURLMOPT_SOCKETFUNCTION, (curl_socket_callback) NULL);
        }
    } else if (option >= CURLOPTTYPE_OFF_T) {
        result = forward(multi, option, va_arg(arguments, curl_off_t));
    } else if (option >= CURLOPTTYPE_OBJECTPOINT) {
        result = forward(multi, option, va_arg(arguments, void *));
    } else {
        result = forward(multi, option, va_arg(arguments, long));
    }
    va_end(arguments);
    return result;
}

/** libcurl's own function, standing in for it to drop the multi handle's relay. */
CURLMcode curl_multi_cleanup(CURLM *multi) {
    static cleanup_fn forward;
    if (!forward) forward = (cleanup_fn) dlsym(RTLD_NEXT, "curl_multi_cleanup");
    if (!forward) return CURLM_INTERNAL_ERROR;
    CURLMcode result = forward(multi);
    relay_forget(multi);
    return result;
}
