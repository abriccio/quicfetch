#ifndef API_H
#define API_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque updater state
typedef struct Updater Updater;

typedef void (*check_version_cb)(Updater *u, bool needs_update);
typedef void (*download_cb)(Updater *u, char *bytes, size_t size);

// cb -- Callback from fetch thread with version check result. Don't call any
// library functions from it since it wants to yield right after calling.
Updater *updater_init(const char* url, const char *name,
                      const char *current_version, check_version_cb cb);
void updater_deinit(Updater *);
void updater_fetch(Updater *);
const char *updater_get_bin_url(Updater *);

typedef struct DownloadOptions {
    download_cb cb;
    int chunk_size;
    const char *sha256;
} DownloadOptions;
void updater_download_bin(Updater *, const char *, DownloadOptions opt);

#ifdef __cplusplus
}
#endif

#endif
