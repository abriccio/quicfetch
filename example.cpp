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
bool can_quit = false;

void on_check(Updater *u, bool needs_update) {
    if (needs_update) {
        printf("Needs update\n");
        printf("%s\n", updater_get_message(u));
        g_need_update = true;
    }
    else
        printf("Does not need update\n");

    evil = false;
}

void download_progress(Updater *u, size_t cur, size_t size) {
    printf("Downloaded : %zu / %zu\n", cur, size);
    printf("%s\n", updater_get_message(u));
}

void download_finished(Updater *u, bool ok, size_t size) {
    if (ok) {
        printf("Download finished | %zuB\n", size);
        printf("%s\n", updater_get_message(u));
    } else {
        printf("Download failed\n");
        printf("%s\n", updater_get_message(u));
    }
    can_quit = true;
}

int main() {
    Updater *updater = updater_init(
        "https://arborealaudio.com/versions/draft/index.json",
        "OmniAmp",
        "1.0.0"
    );

    updater_fetch(updater, on_check);

    while (evil) {
        SLEEP(500);
    }

    if (g_need_update) {
        updater_download_bin(updater, (DownloadOptions){
                                 .progress = download_progress,
                                 .finished = download_finished,
                                 .dest_dir = NULL,
                                 .chunk_size = 32 * 1024,
                             });
    }

    while (!can_quit) {}
    updater_deinit(updater);
    return 0;
}

