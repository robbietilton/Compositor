#include <stddef.h>
#include <stdint.h>
// Fills the selected pixels of `rgba` (`mask` nonzero) from the rest of the image. `cancelled`, if given, is asked
// between passes on the calling thread, and a fill it stops leaves `rgba` as it was.
// Returns 1 on success, 0 when no source patch exists, -1 on allocation failure, -2 when cancelled.
int content_fill(uint8_t *rgba, size_t stride, const uint8_t *mask, size_t maskStride, int width, int height,
                 int (^cancelled)(void));
