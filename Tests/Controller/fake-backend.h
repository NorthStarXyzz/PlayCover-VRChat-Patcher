#ifndef PCVR_TEST_FAKE_BACKEND_H
#define PCVR_TEST_FAKE_BACKEND_H

#include "../../Controller/pcvr-target.h"
#include "../../Controller/pcvr-status-protocol.h"

pcvr_target_backend_t pcvr_test_fake_target_backend(void);
void pcvr_test_fake_target_set_uid(uid_t uid);
void pcvr_test_fake_target_set_home(const char *home);
void pcvr_test_fake_status_backend(pcvr_status_server_t *server,
                                   int client_descriptor);

#endif
