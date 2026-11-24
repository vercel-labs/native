// The Metal backend, for the window host on macOS.

#ifndef NATIVE_COMPOSITOR_METAL_H
#define NATIVE_COMPOSITOR_METAL_H

#include "backend.h"

/**
 * Creates a Metal backend on the system's default device; destroy it through its vtable. Answers
 * NULL when the machine has no Metal device, or a pipeline fails to build.
 */
CompBackend *comp_metal_backend(void);

/** The same, drawing into `layer`'s drawable when a pass names no target. Takes a CAMetalLayer. */
CompBackend *comp_metal_backend_for_layer(void *layer);

#endif
