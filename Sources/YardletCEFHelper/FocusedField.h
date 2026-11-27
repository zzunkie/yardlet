#ifndef YARDLET_HELPER_FOCUSED_FIELD_H
#define YARDLET_HELPER_FOCUSED_FIELD_H

#include "include/capi/cef_app_capi.h"

/// The application for Chromium's sub-processes: in a renderer it reports the page's focused field
/// (whether it takes text, and which keyboard) to the browser host (FocusedField.c). `framework` is the
/// opened CEF framework. NULL when a function it needs is missing.
cef_app_t *yardlet_helper_app(void *framework);

#endif
