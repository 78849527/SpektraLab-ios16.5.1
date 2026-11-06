#include "../../../engine/src/io/raw_decoder.hpp"

#include <libraw/libraw.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <memory>
#include <string>

namespace {
void write_error(char *destination, std::size_t capacity, const std::string& message) {
    if (!destination || capacity == 0) return;
    std::snprintf(destination, capacity, "%s", message.c_str());
}

int libraw_error(int status, char *error, std::size_t capacity) {
    write_error(error, capacity, std::string("RAW open: ") + LibRaw::strerror(status));
    return 0;
}
}

extern "C" int spk_raw_probe_file(const char *path, std::uint32_t *width,
                                  std::uint32_t *height, char *error,
                                  std::size_t error_capacity) {
    if (!path || !*path || !width || !height) {
        write_error(error, error_capacity, "RAW open: invalid probe arguments");
        return 0;
    }
    try {
        auto raw = std::make_unique<LibRaw>(LIBRAW_OPTIONS_NO_DATAERR_CALLBACK);
        const int status = raw->open_file(path);
        if (status != LIBRAW_SUCCESS) return libraw_error(status, error, error_capacity);
        const auto& sizes = raw->imgdata.sizes;
        std::uint32_t w = sizes.width ? sizes.width : sizes.iwidth;
        std::uint32_t h = sizes.height ? sizes.height : sizes.iheight;
        if ((sizes.flip & 4) != 0) std::swap(w, h);
        if (w < 64 || h < 64 || std::uint64_t(w) * h >= 1000000000ULL) {
            write_error(error, error_capacity, "RAW metadata: invalid sensor dimensions");
            return 0;
        }
        *width = w;
        *height = h;
        return 1;
    } catch (const std::exception& exception) {
        write_error(error, error_capacity, std::string("RAW probe: ") + exception.what());
        return 0;
    } catch (...) {
        write_error(error, error_capacity, "RAW probe: unknown decoder error");
        return 0;
    }
}

extern "C" int spk_raw_decode_file(const char *path, int preview, float **rgb,
                                   std::uint32_t *width, std::uint32_t *height,
                                   std::uint32_t *native_width,
                                   std::uint32_t *native_height,
                                   char *error, std::size_t error_capacity) {
    if (!path || !*path || !rgb || !width || !height ||
        !native_width || !native_height) {
        write_error(error, error_capacity, "RAW decode: invalid decoder arguments");
        return 0;
    }
    *rgb = nullptr;
    try {
        spk::io::DecodedRaw decoded;
        std::string message;
        if (!spk::io::decode_raw_compatible(
                std::filesystem::path(path), decoded, message, preview != 0)) {
            write_error(error, error_capacity, message);
            return 0;
        }
        const std::uint64_t samples =
            std::uint64_t(decoded.width) * decoded.height * 3;
        if (samples == 0 || samples > SIZE_MAX / sizeof(float) ||
            decoded.rgb.size() != samples) {
            write_error(error, error_capacity, "RAW decode: invalid output buffer size");
            return 0;
        }
        auto *copy = static_cast<float *>(std::malloc(
            static_cast<std::size_t>(samples) * sizeof(float)));
        if (!copy) {
            write_error(error, error_capacity, "RAW decode: not enough memory");
            return 0;
        }
        std::memcpy(copy, decoded.rgb.data(),
                    static_cast<std::size_t>(samples) * sizeof(float));
        *rgb = copy;
        *width = decoded.width;
        *height = decoded.height;
        auto nativeW = decoded.metadata.sizes_before_postprocess.iwidth;
        auto nativeH = decoded.metadata.sizes_before_postprocess.iheight;
        if ((decoded.metadata.raw_flip & 4) != 0) std::swap(nativeW, nativeH);
        *native_width = nativeW ? nativeW : decoded.width;
        *native_height = nativeH ? nativeH : decoded.height;
        return 1;
    } catch (const std::exception& exception) {
        write_error(error, error_capacity, std::string("RAW decode: ") + exception.what());
        return 0;
    } catch (...) {
        write_error(error, error_capacity, "RAW decode: unknown decoder error");
        return 0;
    }
}

extern "C" void spk_raw_free_buffer(void *buffer) {
    std::free(buffer);
}
