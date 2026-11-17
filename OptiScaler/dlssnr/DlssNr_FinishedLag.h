#pragma once
#include "DlssNr_FinishedConsumer.h"

namespace DlssNr
{
// Owned by one LateContext, under its existing state mutex. No process-wide policy.
struct FinishedLag1
{
    FinishedIdentity scope {};
    uint64_t application = 0, serial = 0, restamped = 0;
    unsigned streak = 0;
    bool locked = false;

    void Reset() { *this = {}; }

    void Enter(const void* owner, const FinishedIdentity& request)
    {
        if (!request.Known() || !request.applicationKnown)
        {
            Reset();
            return;
        }
        if (scope.owner != owner || !scope.SameConsumer(request) || request.application < application)
        {
            Reset();
            scope = request;
            scope.owner = owner;
        }
    }

    void Exact(uint64_t matchedSerial)
    {
        // A second query/claim of the slot just restamped must retain the learned phase.
        if (matchedSerial != restamped)
        {
            application = serial = restamped = 0;
            streak = 0;
            locked = false;
        }
    }

    bool Observe(uint64_t nextApplication, uint64_t nextSerial)
    {
        if (application == nextApplication)
        {
            if (serial != nextSerial)
            {
                streak = 0;
                locked = false;
            }
            return locked;
        }
        const bool consecutive = application && nextApplication == application + 1;
        streak = consecutive ? (streak < 3 ? streak + 1 : 3) : 1;
        application = nextApplication;
        serial = nextSerial;
        locked = streak >= 3;
        if (locked)
            restamped = nextSerial;
        return locked;
    }
};
}
