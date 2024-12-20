#include "include/quicfetch.h"

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

void on_check(Updater *u, bool needs_update, void *user_data) {
    if (needs_update) {
        printf("Needs update\n");
        g_need_update = true;
    }
    const char *msg = updater_get_message(u);
    printf("%s\n", msg);
}

void download_progress(Updater *u, size_t cur, size_t size, void *user_data) {
    printf("Downloaded : %zukB / %zukB | %.2f%%\n", cur / 1024, size / 1024,
         (float)cur / (float)size * 100.f);
}

void download_finished(Updater *u, bool ok, size_t size, void *user_data) {
    if (ok) {
        printf("Download finished | %zukB\n", size/1024);
    } else {
        printf("Download failed\n");
        printf("%s\n", updater_get_message(u));
    }
    evil = false;
}

void on_activation(bool success, const char* msg, size_t msg_len, void *user_data) {
    puts(msg);
    // lol why isn't printf working here?
    // printf("%s\n", msg);
    evil = false;
}

int main() {
    Updater *updater = updater_init(
        "https://arborealaudio.com/versions/draft/index.json",
        "OmniAmp",
        "1.0.0",
        NULL
    );

    updater_fetch(updater, on_check);

    while (evil) {
        SLEEP(500);
        if (g_need_update) {
            updater_download_bin(updater, (DownloadOptions){
                                     .progress = download_progress,
                                     .finished = download_finished,
                                     .dest_file = NULL,
                                     .chunk_size = 32 * 1024,
                                 });
            g_need_update = false;
        }
    }

    updater_deinit(updater);

    evil = true;
    activation_check("https://3pvj52nx17.execute-api.us-east-1.amazonaws.com/"
                     "default/licenses/",
                     "OMNIAMP-TEST-LICENSE", AWS_API_KEY, on_activation, NULL);
    while (evil) {
        SLEEP(1000);
    }

    return 0;
}

