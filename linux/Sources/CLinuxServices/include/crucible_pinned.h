#ifndef CRUCIBLE_PINNED_H
#define CRUCIBLE_PINNED_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/** Whether the server whose leaf certificate has this SHA-256 fingerprint (lowercase hex) may answer. */
typedef bool (*crucible_pinned_verify)(void *context, const char *fingerprint);

typedef struct {
    long status;
    uint8_t *body;
    size_t body_length;
    /** The response's header lines, each ending in CRLF, as the server sent them. */
    char *headers;
} crucible_pinned_response;

/** Sends one HTTPS request to a server with a self-made certificate. The certificate is checked by `verify` inside the TLS
 * handshake, before anything of the request is sent, and TLS sessions are never resumed, so every request meets the
 * check. `headers` are "Name: value" lines. Returns 0 with `response` filled (free it with `crucible_pinned_free`), or
 * curl's error code when nothing came back, including a certificate `verify` refused. */
int crucible_pinned_send(const char *method, const char *url, const char *const *headers, size_t header_count, const uint8_t *body,
                         size_t body_length, double timeout_seconds, crucible_pinned_verify verify, void *context,
                         crucible_pinned_response *response);
void crucible_pinned_free(crucible_pinned_response *response);

#endif
