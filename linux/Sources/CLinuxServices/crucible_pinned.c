#include "crucible_pinned.h"

#include <curl/curl.h>
#include <openssl/evp.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

struct pin {
    crucible_pinned_verify verify;
    void *context;
};

struct buffer {
    uint8_t *bytes;
    size_t length;
};

static size_t append(char *data, size_t size, size_t count, void *userdata) {
    struct buffer *buffer = userdata;
    size_t added = size * count;
    uint8_t *grown = realloc(buffer->bytes, buffer->length + added + 1);
    if (!grown) return 0;
    memcpy(grown + buffer->length, data, added);
    buffer->bytes = grown;
    buffer->length += added;
    buffer->bytes[buffer->length] = 0;
    return added;
}

static int pin_index = -1;
static pthread_once_t pin_index_once = PTHREAD_ONCE_INIT;

static void make_pin_index(void) { pin_index = SSL_CTX_get_ex_new_index(0, NULL, NULL, NULL, NULL); }

static const char hex_digits[] = "0123456789abcdef";

/** Checks the leaf certificate against the pin, letting the rest of the chain through: a self-made certificate has no
 * authority to vouch for it, so its fingerprint is the whole check. */
static int verify_certificate(int preverified, X509_STORE_CTX *store) {
    if (X509_STORE_CTX_get_error_depth(store) != 0) return 1;
    SSL *ssl = X509_STORE_CTX_get_ex_data(store, SSL_get_ex_data_X509_STORE_CTX_idx());
    struct pin *pin = ssl ? SSL_CTX_get_ex_data(SSL_get_SSL_CTX(ssl), pin_index) : NULL;
    X509 *certificate = X509_STORE_CTX_get_current_cert(store);
    unsigned char digest[EVP_MAX_MD_SIZE];
    unsigned int length = 0;
    if (!pin || !certificate || !X509_digest(certificate, EVP_sha256(), digest, &length)) return 0;
    char hex[EVP_MAX_MD_SIZE * 2 + 1];
    for (unsigned int i = 0; i < length; i++) {
        hex[i * 2] = hex_digits[digest[i] >> 4];
        hex[i * 2 + 1] = hex_digits[digest[i] & 0x0f];
    }
    hex[length * 2] = 0;
    if (!pin->verify(pin->context, hex)) return 0;
    X509_STORE_CTX_set_error(store, X509_V_OK);
    return 1;
}

static CURLcode configure_context(CURL *curl, void *ssl_context, void *userdata) {
    SSL_CTX *context = ssl_context;
    SSL_CTX_set_ex_data(context, pin_index, userdata);
    SSL_CTX_set_verify(context, SSL_VERIFY_PEER, verify_certificate);
    return CURLE_OK;
}

int crucible_pinned_send(const char *method, const char *url, const char *const *headers, size_t header_count, const uint8_t *body,
                         size_t body_length, double timeout_seconds, crucible_pinned_verify verify, void *context,
                         crucible_pinned_response *response) {
    memset(response, 0, sizeof(*response));
    pthread_once(&pin_index_once, make_pin_index);
    const curl_version_info_data *version = curl_version_info(CURLVERSION_NOW);
    if (!version->ssl_version || strncmp(version->ssl_version, "OpenSSL", 7) != 0) return CURLE_SSL_ENGINE_NOTFOUND;
    CURL *curl = curl_easy_init();
    if (!curl) return CURLE_FAILED_INIT;
    struct pin pin = { verify, context };
    struct buffer received = { 0 }, header_lines = { 0 };
    struct curl_slist *list = NULL;
    for (size_t i = 0; i < header_count; i++) list = curl_slist_append(list, headers[i]);
    list = curl_slist_append(list, "Expect:");
    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, method);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, list);
    if (body && body_length > 0) {
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body);
        curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t) body_length);
    } else if (strcmp(method, "GET") != 0) {
        curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t) 0);
    }
    curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, (long) (timeout_seconds * 1000));
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(curl, CURLOPT_PROXY, "");
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 0L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 0L);
    curl_easy_setopt(curl, CURLOPT_SSL_SESSIONID_CACHE, 0L);
    curl_easy_setopt(curl, CURLOPT_SSL_CTX_FUNCTION, configure_context);
    curl_easy_setopt(curl, CURLOPT_SSL_CTX_DATA, &pin);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, append);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &received);
    curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, append);
    curl_easy_setopt(curl, CURLOPT_HEADERDATA, &header_lines);
    CURLcode result = curl_easy_perform(curl);
    if (result == CURLE_OK) {
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &response->status);
        response->body = received.bytes;
        response->body_length = received.length;
        response->headers = (char *) header_lines.bytes;
    } else {
        free(received.bytes);
        free(header_lines.bytes);
    }
    curl_slist_free_all(list);
    curl_easy_cleanup(curl);
    return (int) result;
}

void crucible_pinned_free(crucible_pinned_response *response) {
    free(response->body);
    free(response->headers);
    memset(response, 0, sizeof(*response));
}
