/*
 * BatteryGuardSMCReader
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * This standalone read-only helper uses the AppleSMC user-client ABI derived
 * from hholtmann/smcFanControl's smc-command. It deliberately exposes no write
 * operation and returns data only when all expected battery sensors succeed.
 */

#include <IOKit/IOKitLib.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

enum {
    kSMCUserClientMethod = 2,
    kSMCReadBytes = 5,
    kSMCReadKeyInfo = 9,
};

typedef struct {
    uint8_t major;
    uint8_t minor;
    uint8_t build;
    uint8_t reserved;
    uint16_t release;
} SMCVersion;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuLimit;
    uint32_t gpuLimit;
    uint32_t memoryLimit;
} SMCPowerLimitData;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
} SMCKeyInfo;

typedef struct {
    uint32_t key;
    SMCVersion version;
    SMCPowerLimitData powerLimitData;
    SMCKeyInfo keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t command;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData;

_Static_assert(sizeof(SMCKeyData) == 80, "Unexpected SMCKeyData layout");

typedef struct {
    char key[5];
    char type[5];
    uint32_t size;
    uint8_t bytes[32];
    float value;
} TemperatureReading;

static uint32_t fourCharacterCode(const char text[4]) {
    return ((uint32_t)(uint8_t)text[0] << 24)
        | ((uint32_t)(uint8_t)text[1] << 16)
        | ((uint32_t)(uint8_t)text[2] << 8)
        | (uint32_t)(uint8_t)text[3];
}

static void decodeFourCharacterCode(uint32_t code, char output[5]) {
    output[0] = (char)(code >> 24);
    output[1] = (char)(code >> 16);
    output[2] = (char)(code >> 8);
    output[3] = (char)code;
    output[4] = '\0';
}

static kern_return_t callSMC(
    io_connect_t connection,
    SMCKeyData *input,
    SMCKeyData *output
) {
    size_t outputSize = sizeof(*output);
    return IOConnectCallStructMethod(
        connection,
        kSMCUserClientMethod,
        input,
        sizeof(*input),
        output,
        &outputSize
    );
}

static kern_return_t readTemperature(
    io_connect_t connection,
    const char key[4],
    TemperatureReading *reading
) {
    SMCKeyData input = {0};
    SMCKeyData output = {0};
    input.key = fourCharacterCode(key);
    input.command = kSMCReadKeyInfo;

    kern_return_t result = callSMC(connection, &input, &output);
    if (result != KERN_SUCCESS) {
        return result;
    }
    if (output.result != 0) {
        return kIOReturnError;
    }
    if (output.keyInfo.dataSize == 0 || output.keyInfo.dataSize > sizeof(output.bytes)) {
        return kIOReturnBadArgument;
    }

    uint32_t dataType = output.keyInfo.dataType;
    input.keyInfo.dataSize = output.keyInfo.dataSize;
    input.command = kSMCReadBytes;
    memset(&output, 0, sizeof(output));
    result = callSMC(connection, &input, &output);
    if (result != KERN_SUCCESS) {
        return result;
    }
    if (output.result != 0) {
        return kIOReturnError;
    }

    memset(reading, 0, sizeof(*reading));
    memcpy(reading->key, key, 4);
    decodeFourCharacterCode(dataType, reading->type);
    reading->size = input.keyInfo.dataSize;
    memcpy(reading->bytes, output.bytes, reading->size);

    if (dataType != fourCharacterCode("flt ") || reading->size != 4) {
        return kIOReturnUnsupported;
    }
    memcpy(&reading->value, reading->bytes, sizeof(reading->value));

    if (!isfinite(reading->value) || reading->value < -20.0f || reading->value > 120.0f) {
        return kIOReturnBadArgument;
    }
    return KERN_SUCCESS;
}

static void printReading(const TemperatureReading *reading) {
    printf(
        "%s [%.4s] %.3f (bytes",
        reading->key,
        reading->type,
        reading->value
    );
    for (uint32_t index = 0; index < reading->size; index += 1) {
        printf(" %02x", reading->bytes[index]);
    }
    printf(")\n");
}

int main(void) {
    io_service_t service = IOServiceGetMatchingService(
        kIOMainPortDefault,
        IOServiceMatching("AppleSMC")
    );
    if (service == IO_OBJECT_NULL) {
        fprintf(stderr, "AppleSMC service is unavailable\n");
        return 1;
    }

    io_connect_t connection = IO_OBJECT_NULL;
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &connection);
    IOObjectRelease(service);
    if (result != KERN_SUCCESS) {
        fprintf(stderr, "AppleSMC connection failed: 0x%08x\n", result);
        return 1;
    }

    static const char keys[][5] = {"TB0T", "TB1T", "TB2T"};
    TemperatureReading readings[3] = {0};
    int exitCode = 0;
    for (size_t index = 0; index < 3; index += 1) {
        result = readTemperature(connection, keys[index], &readings[index]);
        if (result != KERN_SUCCESS) {
            fprintf(stderr, "SMC read failed for %s: 0x%08x\n", keys[index], result);
            exitCode = 2;
            break;
        }
    }
    IOServiceClose(connection);

    if (exitCode != 0) {
        return exitCode;
    }
    for (size_t index = 0; index < 3; index += 1) {
        printReading(&readings[index]);
    }
    return 0;
}
