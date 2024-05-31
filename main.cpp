#include "api.h"

#include <stdio.h>
#include <stdlib.h>
#include <time.h>

bool evil = true;
bool g_need_update = false;

void on_check(Updater *u, bool needs_update) {
    if (needs_update) {
        printf("Needs update\n");
        g_need_update = true;
    }
    else
        printf("Does not need update\n");

    evil = false;
}

void on_download(Updater *u, char *bytes, size_t size) {
    printf("Download size: %zu\n", size);
}

int main() {
    Updater *updater = updater_init(
        "http://localhost:1313/versions/draft/index.json",
        "PiMax",
        "1.1.0",
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
                                 .cb = on_download,
                                 .chunk_size = 64 * 1024,
                                 .sha256 = "",
                             });
    }

    updater_deinit(updater);
    return 0;
}

