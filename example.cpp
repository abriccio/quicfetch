#include "quicfetch.h"

#include <stdio.h>
#include <stdlib.h>
#ifdef WIN32
#include <windows.h>
#define SLEEP(ms) Sleep(ms)
#else
#include <time.h>
#include <unistd.h>
#define SLEEP(ms) struct timespec ts = {.tv_nsec=(ms)*1000}; nanosleep(&ts, NULL)
#endif


bool evil = true;
bool g_need_update = false;

void on_check(Updater *u, bool needs_update) {
    if (needs_update) {
        printf("Needs update\n");
        g_need_update = true;
    }
    else
        printf("Does not need update\n");
}

void download_progress(Updater *u, size_t cur, size_t size) {
    printf("Downloaded : %zu / %zu\n", cur, size);
}

void download_finished(Updater *u, bool ok, size_t size) {
    if (ok) {
        printf("Download finished | %zuB\n", size);
    } else {
        printf("Download failed\n");
    }
    evil = false;
}

int main() {
    Updater *updater = updater_init(
        "https://arborealaudio.com/versions/draft/index.json",
        "PiMax",
        "1.0.0"
    );

    updater_fetch(updater, on_check);

    while (evil) {
        SLEEP(500);
        if (g_need_update) {
            updater_download_bin(updater, (DownloadOptions){
                                     .progress = download_progress,
                                     .finished = download_finished,
                                     .dest_dir = NULL,
                                     .chunk_size = 32 * 1024,
                                 });
        }
    }

    updater_deinit(updater);
    return 0;
}

