#include <IOKit/IOKitLib.h>
#include <math.h>
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "SMCTemperatureReaderTestBridge.h"

static kern_return_t BGTestIOConnectCallStructMethod(
    mach_port_t connection,
    uint32_t selector,
    const void *inputStruct,
    size_t inputStructSize,
    void *outputStruct,
    size_t *outputStructSize
);

#define BG_IO_CONNECT_CALL BGTestIOConnectCallStructMethod
#define main BGSMCReaderMainForTests
#include "../SMCTemperatureReader/main.c"
#undef main
#undef BG_IO_CONNECT_CALL

enum {
    kBGScenarioSuccess = 0,
    kBGScenarioKeyInfoResponseError = 1,
    kBGScenarioReadResponseError = 2,
    kBGScenarioShortKeyInfoOutput = 3,
    kBGScenarioShortReadOutput = 4,
    kBGScenarioInvalidType = 5,
    kBGScenarioInvalidSize = 6,
    kBGScenarioNonfiniteValue = 7,
    kBGScenarioImplausibleValue = 8,
    kBGScenarioTransportFailure = 9,
};

static int32_t currentScenario = kBGScenarioSuccess;
static int callCount = 0;
static pthread_mutex_t scenarioLock = PTHREAD_MUTEX_INITIALIZER;

static kern_return_t BGTestIOConnectCallStructMethod(
    mach_port_t connection,
    uint32_t selector,
    const void *inputStruct,
    size_t inputStructSize,
    void *outputStruct,
    size_t *outputStructSize
) {
    (void)connection;
    (void)selector;
    (void)inputStruct;
    (void)inputStructSize;

    SMCKeyData *output = outputStruct;
    memset(output, 0, sizeof(*output));
    *outputStructSize = sizeof(*output);

    if (currentScenario == kBGScenarioTransportFailure) {
        return kIOReturnNotResponding;
    }

    if (callCount++ == 0) {
        if (currentScenario == kBGScenarioShortKeyInfoOutput) {
            *outputStructSize = offsetof(SMCKeyData, keyInfo);
            return KERN_SUCCESS;
        }
        output->result = currentScenario == kBGScenarioKeyInfoResponseError ? 1 : 0;
        output->keyInfo.dataSize = currentScenario == kBGScenarioInvalidSize ? 5 : 4;
        output->keyInfo.dataType = currentScenario == kBGScenarioInvalidType
            ? fourCharacterCode("sp78")
            : fourCharacterCode("flt ");
        return KERN_SUCCESS;
    }

    if (currentScenario == kBGScenarioShortReadOutput) {
        *outputStructSize = offsetof(SMCKeyData, bytes);
        return KERN_SUCCESS;
    }
    output->result = currentScenario == kBGScenarioReadResponseError ? 1 : 0;
    float value = 42.25f;
    if (currentScenario == kBGScenarioNonfiniteValue) {
        value = NAN;
    } else if (currentScenario == kBGScenarioImplausibleValue) {
        value = 150.0f;
    }
    memcpy(output->bytes, &value, sizeof(value));
    return KERN_SUCCESS;
}

int32_t BGTestReadTemperatureScenario(int32_t scenario, float *value) {
    pthread_mutex_lock(&scenarioLock);
    currentScenario = scenario;
    callCount = 0;
    TemperatureReading reading = {0};
    kern_return_t result = readTemperature(0, "TB0T", &reading);
    if (result == KERN_SUCCESS && value != NULL) {
        *value = reading.value;
    }
    pthread_mutex_unlock(&scenarioLock);
    return result;
}
