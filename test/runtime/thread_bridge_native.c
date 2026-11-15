#include <pthread.h>
#include <sched.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct { unsigned long raw; } CynaThread;
typedef struct { bool settled; int32_t code; CynaThread handle; } CynaThreadOpRaw;

extern CynaThreadOpRaw cyna_std_thread_join(CynaThread thread);
extern CynaThreadOpRaw cyna_std_thread_detach(CynaThread thread);

#define CHECK(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "thread bridge check failed at %s:%d: %s\n", __FILE__, __LINE__, #condition); \
        abort(); \
    } \
} while (0)

static atomic_bool completed;

static void *mark_completed(void *unused) {
    (void)unused;
    atomic_store(&completed, true);
    return NULL;
}

int main(void) {
    pthread_t joined_thread;
    atomic_store(&completed, false);
    CHECK(pthread_create(&joined_thread, NULL, mark_completed, NULL) == 0);
    const CynaThreadOpRaw joined = cyna_std_thread_join((CynaThread){ .raw = (unsigned long)joined_thread });
    CHECK(joined.settled);
    CHECK(joined.handle.raw == 0);
    CHECK(atomic_load(&completed));

    pthread_t detached_thread;
    atomic_store(&completed, false);
    CHECK(pthread_create(&detached_thread, NULL, mark_completed, NULL) == 0);
    const CynaThreadOpRaw detached = cyna_std_thread_detach((CynaThread){ .raw = (unsigned long)detached_thread });
    CHECK(detached.settled);
    CHECK(detached.handle.raw == 0);
    for (unsigned i = 0; i < 1000000 && !atomic_load(&completed); ++i) sched_yield();
    CHECK(atomic_load(&completed));

    const CynaThreadOpRaw failed_join = cyna_std_thread_join((CynaThread){ .raw = 0 });
    CHECK(!failed_join.settled);
    CHECK(failed_join.code == 2);
    CHECK(failed_join.handle.raw == 0);

    const CynaThreadOpRaw failed_detach = cyna_std_thread_detach((CynaThread){ .raw = 0 });
    CHECK(!failed_detach.settled);
    CHECK(failed_detach.code == 3);
    CHECK(failed_detach.handle.raw == 0);
    return 0;
}
