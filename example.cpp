#include "api.h"

#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

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

void download_finished(Updater *u, bool ok, size_t size) {
    if (ok)
        printf("Download finished | %zuB\n", size);
    else
        printf("Download failed\n");
    can_quit = true;
}

int main() {
    Updater *updater = updater_init(
        "https://arborealaudio.com/versions/draft/index.json",
        "PiMax",
        "1.0.0"
    );

    updater_fetch(updater, on_check);

    while (evil) {
        struct timespec sleep_time = {
            .tv_nsec = 500 * 1000,
        };
        nanosleep(&sleep_time, NULL);
    }

    if (g_need_update) {
        char buf[64] = {0};
        const char *cwd = getcwd(buf, sizeof(buf));
        updater_download_bin(updater, (DownloadOptions){
                                 .progress = download_progress,
                                 .finished = download_finished,
                                 .dest_dir = cwd,
                                 .chunk_size = 32 * 1024,
                             });
    }

    while (!can_quit) {}
    updater_deinit(updater);
    return 0;
}

