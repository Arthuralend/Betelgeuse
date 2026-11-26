#ifndef BETELGEUSE_CORE_H
#define BETELGEUSE_CORE_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct BglEngine BglEngine;
/* All returned strings are owned by Rust; release with bgl_string_free.
 * Identity is private serialized Ed25519 material; use secure platform storage.
 * Native clients must serialize operations on a handle and close exactly once.
 * Do not use a handle after close. All text uses UTF-8. */
char *bgl_generate_identity(void);
BglEngine *bgl_open(const char *directory, const char *identity, const char *options_json);
int32_t bgl_send(BglEngine *engine, const char *command_json);
char *bgl_poll(BglEngine *engine);
char *bgl_last_error(void);
void bgl_string_free(char *value);
void bgl_close(BglEngine *engine);
#ifdef __cplusplus
}
#endif
#endif
