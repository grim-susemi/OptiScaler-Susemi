// Integration cases execute the actual production admission, Cancel and capture reset bodies.
static bool LagQuery(Fixture& f, uint64_t application)
{
    auto& slot = f.state.late.slots[0];
    f.consumer.application = application;
    slot.identity = f.consumer;
    slot.identity.application = application - 1;
    slot.serial = application;
    slot.pending = true;
    DlssNr::XeFGCapture facts;
    return f.Admit(facts) && facts.ready;
}
static void WarmLag(Fixture& f)
{
    Expect(!LagQuery(f,100) && !LagQuery(f,101) && LagQuery(f,102), "NR_LAG_THREE_FRAMES");
    DlssNr::XeFGCapture facts;
    Expect(f.Admit(facts,true), "NR_LAG_CLAIM");
}
static void LagCases()
{
    {
        Fixture f;
        Expect(!LagQuery(f,100), "NR_LAG_INITIAL");
        for (unsigned i=0;i<4;++i) Expect(!LagQuery(f,100), "NR_LAG_REPEAT_COUNTS_ONCE");
        Expect(!LagQuery(f,101) && LagQuery(f,102), "NR_LAG_UNIQUE_FRAMES");
        DlssNr::XeFGCapture facts;
        Expect(f.Admit(facts,true) && LagQuery(f,103), "NR_LAG_CLAIM_RETAINS");
    }
    for (unsigned transition=0;transition<4;++transition)
    {
        Fixture f;
        WarmLag(f);
        if (transition==0) ++f.consumer.generation;
        if (transition==1) f.consumer.consumer=&f.motion;
        if (transition==2) f.state.late.Cancel();
        if (transition==3) f.state.late.CapturedReset(true);
        Expect(!LagQuery(f,103), transition==2 ? "NR_LAG_CANCEL" :
               transition==3 ? "NR_LAG_CAPTURE_RESET" : "NR_LAG_SCOPE_RESET");
        Expect(!LagQuery(f,104) && LagQuery(f,105), "NR_LAG_RELEARN");
    }
    {
        Fixture a,b;
        WarmLag(a);
        Expect(!LagQuery(b,100) && LagQuery(a,103) && !LagQuery(b,101), "NR_LAG_OWNER_ISOLATION");
    }
    {
        Fixture f;
        WarmLag(f);
        LagQuery(f,103);
        auto& extra=f.state.late.slots[1];
        extra=f.state.late.slots[0];
        extra.identity.application=f.consumer.application;
        extra.serial=1000;
        DlssNr::XeFGCapture facts;
        Expect(f.Admit(facts) && facts.ready && facts.serial==1000, "NR_LAG_EXACT_FIRST");
        extra.pending=false;
        Expect(!LagQuery(f,104), "NR_LAG_EXACT_DROPS_LEARNING");
    }
    {
        Fixture f;
        WarmLag(f);
        LagQuery(f,103);
        auto& slot=f.state.late.slots[0];
        slot.identity.application=102;
        auto& extra=f.state.late.slots[1];
        extra=slot;
        ++extra.serial;
        DlssNr::XeFGCapture facts;
        Expect(!f.Admit(facts), "NR_LAG_AMBIGUITY");
        extra.pending=false;
        Expect(!LagQuery(f,104), "NR_LAG_AMBIGUITY_RESETS");
    }
    {
        Fixture f;
        WarmLag(f);
        Expect(!LagQuery(f,105), "NR_LAG_GAP_RESETS");
        Expect(!LagQuery(f,90), "NR_LAG_REGRESSION_RESETS");
    }
    std::puts("PASS NR_LAG: claim, exact-first, duplicate-query, owner/consumer/generation, Cancel/capture-reset, ambiguity, frame gaps");
}
