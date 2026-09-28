#ifndef TOHOST_H
#define TOHOST_H
#include "soc.h"
static inline void tohost(uint32_t v) {
    TOHOST = (uint8_t)v;
}
#endif
