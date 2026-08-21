#include "RuntimeRootPathProjection.h"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/param.h>

int ForgePlayRuntimeRootPathProjectionCopyCurrentPath(
    int descriptor,
    char *destination,
    size_t capacity
) {
    if (descriptor < 0 || destination == NULL) {
        return EINVAL;
    }
    if (capacity < MAXPATHLEN) {
        return ENAMETOOLONG;
    }

    destination[0] = '\0';
    if (fcntl(descriptor, F_GETPATH, destination) == -1) {
        return errno == 0 ? EIO : errno;
    }
    if (destination[0] != '/' || memchr(destination, '\0', capacity) == NULL) {
        destination[0] = '\0';
        return EINVAL;
    }
    return 0;
}
