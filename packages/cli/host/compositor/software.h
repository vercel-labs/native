// The software backend, for hosts and tests with no GPU.

#ifndef NATIVE_COMPOSITOR_SOFTWARE_H
#define NATIVE_COMPOSITOR_SOFTWARE_H

#include "backend.h"

/** Creates a Cairo-backed backend; destroy it through its vtable's destroy. */
CompBackend *comp_software_backend(void);

#endif
