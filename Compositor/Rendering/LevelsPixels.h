#include <stdint.h>
#include <stddef.h>
void levels_apply(uint8_t *pixels, size_t count, const float *tables);
void levels_histogram(const uint8_t *pixels, const uint8_t *coverage, size_t count, double *bins);
void cube_apply(uint8_t *pixels, size_t count, const float *cube, int dimension);
