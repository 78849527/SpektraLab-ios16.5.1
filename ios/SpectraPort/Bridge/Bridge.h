// Keep the original C ABI. Do not expose C++ objects to Swift.
// Original engine copyright and licence remain in engine/ and LICENSE.txt.
#pragma once
#include "spektrafilm/spk_engine.h"

#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
int spk_raw_probe_file(const char *path, uint32_t *width, uint32_t *height,
                       char *error, size_t error_capacity);
int spk_raw_decode_file(const char *path, int preview, float **rgb,
                        uint32_t *width, uint32_t *height,
                        uint32_t *native_width, uint32_t *native_height,
                        char *error, size_t error_capacity);
void spk_raw_free_buffer(void *buffer);
#ifdef __cplusplus
}
#endif
