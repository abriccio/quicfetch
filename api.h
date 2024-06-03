#ifndef API_H
#define API_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque updater state
typedef struct Updater Updater;

typedef void (*check_version_cb)(Updater *u, bool needs_update);
typedef void (*download_progress_cb)(Updater *u, size_t cur, size_t size);
typedef void (*download_finished_cb)(Updater *u, bool ok, size_t size);

Updater *updater_init(const char* url, const char *name,
                      const char *current_version);
void updater_deinit(Updater *);
// cb -- Callback from fetch thread with version check result. Don't call any
// library functions from it since it wants to yield right after calling.
void updater_fetch(Updater *, check_version_cb cb);

typedef struct DownloadOptions {
    download_progress_cb progress;
    download_finished_cb finished;
    const char *dest_dir;
    int chunk_size;
} DownloadOptions;
// Will automatically use the OS-appropriate download URL
void updater_download_bin(Updater *, DownloadOptions opt);

#ifdef __cplusplus
}
#endif

#endif
