#include "api.h"

#include <stdio.h>
#include <stdlib.h>
#include <time.h>

bool evil = true;
bool g_need_update = false;
bool can_quit = false;

void on_check(Updater *u, bool needs_update) {
    if (needs_update) {
        printf("Needs update\n");
        g_need_update = true;
    }
    else
        printf("Does not need update\n");

    evil = false;
}

void download_progress(Updater *u, size_t cur, size_t size) {
    printf("Downloaded : %zu / %zu\n", cur, size);
}

void download_finished(Updater *u, char *data, size_t size) {
    printf("Download finished | %zuB\n", size);
    can_quit = true;
}

int main() {
    Updater *updater = updater_init(
        "https://arborealaudio.com/versions/index.json",
        "OmniAmp",
        "1.0.0",
        on_check
    );

    updater_fetch(updater);

    while (evil) {
        struct timespec sleep_time = {
            .tv_nsec = 500 * 1000,
        };
        nanosleep(&sleep_time, NULL);
    }

    if (g_need_update) {
        const char *bin_url = updater_get_bin_url(updater);
        printf("Downloading from %s\n", bin_url);
        updater_download_bin(updater, bin_url, (DownloadOptions){
                                 .progress = download_progress,
                                 .finished = download_finished,
                                 .chunk_size = 32 * 1024,
                                 .sha256 = "",
                             });
    }

    while (!can_quit) {}
    updater_deinit(updater);
    return 0;
}

