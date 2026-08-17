#ifndef RF_TYPES_H
#define RF_TYPES_H

#include <stdbool.h>
#include <stdint.h>

typedef enum {
    RF_STATUS_OK = 0,
    RF_STATUS_INVALID_ARGUMENT,
    RF_STATUS_OUT_OF_RANGE,
    RF_STATUS_POWER_OFF,
    RF_STATUS_NOT_READY,
    RF_STATUS_FAULT_LATCHED,
    RF_STATUS_IO_ERROR
} rf_status_t;

typedef enum {
    RF_CHANNEL_1 = 0,
    RF_CHANNEL_2 = 1
} rf_channel_t;

typedef enum {
    RF_CHANNEL_MASK_1 = 0x01u,
    RF_CHANNEL_MASK_2 = 0x02u,
    RF_CHANNEL_MASK_ALL = 0x03u
} rf_channel_mask_t;

typedef enum {
    RF_POWER_OFF = 0,
    RF_POWER_STARTING,
    RF_POWER_READY,
    RF_POWER_STOPPING,
    RF_POWER_EXTERNAL_SAFE,
    RF_POWER_FAULT
} rf_power_state_t;

typedef enum {
    RF_POWER_SOURCE_NONE = 0,
    RF_POWER_SOURCE_INTERNAL,
    RF_POWER_SOURCE_EXTERNAL
} rf_power_source_t;

typedef enum {
    RF_FAULT_NONE = 0,
    RF_FAULT_COMM_TIMEOUT,
    RF_FAULT_USB_DISCONNECTED,
    RF_FAULT_INIT_FAILURE
} rf_fault_t;

#define RF_ATTENUATION_MAX_STEPS 63u
#define RF_PHASE_MAX_STEPS 15u

#endif
