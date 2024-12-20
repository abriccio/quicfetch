#ifndef API_H
#define API_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Updater API
// Opaque updater state
typedef struct Updater Updater;

#define MSG_BUF_SIZE 256

typedef void (*check_version_cb)(Updater *u, bool needs_update, void *user_data);
typedef void (*download_progress_cb)(Updater *u, size_t read, size_t total, void *user_data);
typedef void (*download_finished_cb)(Updater *u, bool ok, size_t size, void *user_data);

Updater *updater_init(const char *url, const char *name,
                      const char *current_version,
                      void *user_data);
void updater_deinit(Updater *);
// cb -- Callback from fetch thread with version check result. Don't call any
// library functions from it since it wants to yield right after calling.
// Call `updater_get_message` to read about the update.
void updater_fetch(Updater *, check_version_cb cb);
const char *updater_get_message(Updater *);

typedef struct DownloadOptions {
    download_progress_cb progress;
    download_finished_cb finished;
    const char *dest_file;
    int chunk_size;
} DownloadOptions;
// Will automatically use the OS-appropriate download URL
void updater_download_bin(Updater *, DownloadOptions opt);

// Activator API
typedef void(*activation_cb)(bool success, const char *msg, size_t msg_len, void *user_data);

void activation_check(const char *url, const char *license, const char *api_key, activation_cb cb, void *user_data);

#ifdef __cplusplus
}
#endif

#endif
