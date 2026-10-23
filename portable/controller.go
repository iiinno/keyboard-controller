package main

import (
    "fmt"
    "time"
)

type Controller struct {
    backend Backend
    cfg Config
    Mode string
    State string
    Reason string
    pauseUntil int64
    settleUntil int64
    lastTick int64
    nextPoll int64
    held string
}

func newController(b Backend, cfg Config) (*Controller, error) {
    if err := cfg.Validate(); err != nil { return nil, err }
    now := b.NowMS()
    return &Controller{backend:b, cfg:cfg, Mode:"AUTO", State:"PASS", Reason:"startup", settleUntil:now+cfg.SettleMS, lastTick:now}, nil
}

func (c *Controller) release(reason string) error {
    if c.held != "" {
        if err := c.backend.Release(); err != nil { c.State="UNKNOWN"; return fmt.Errorf("release failed: %w", err) }
        c.held = ""
    }
    c.State, c.Reason = "PASS", reason
    return nil
}

func (c *Controller) SetMode(mode string) error {
    if mode != "AUTO" && mode != "FORCED_ON" { return fmt.Errorf("unknown mode %q", mode) }
    c.Mode, c.pauseUntil, c.nextPoll = mode, 0, 0
    if mode == "FORCED_ON" { return c.release("forced ON") }
    return nil
}

func (c *Controller) Pause(duration time.Duration) error {
    if duration <= 0 || duration > time.Hour { return fmt.Errorf("pause must be greater than zero and at most one hour") }
    c.Mode, c.pauseUntil = "AUTO", c.backend.NowMS()+duration.Milliseconds()
    return c.release("temporary ON")
}

func (c *Controller) Tick() error {
    now := c.backend.NowMS()
    gap := now-c.lastTick
    c.lastTick = now
    if gap < 0 || gap > c.cfg.PollMS*3+5000 {
        c.settleUntil, c.nextPoll = now+c.cfg.SettleMS, 0
        if err := c.release("resume / timer gap"); err != nil { return err }
    }
    if c.pauseUntil > 0 && now >= c.pauseUntil { c.pauseUntil, c.nextPoll = 0, 0 }
    if c.Mode != "AUTO" || c.pauseUntil > now || now < c.settleUntil {
        return c.release("forced ON / temporary ON / settling")
    }
    if now < c.nextPoll { return nil }
    c.nextPoll = now+c.cfg.PollMS
    devices, err := c.backend.Devices()
    if err != nil { return c.release("device enumeration failed: "+err.Error()) }
    internal, err := uniqueDevice(devices, c.cfg.InternalID, true)
    if err != nil { return c.release(err.Error()) }
    if _, err = uniqueDevice(devices, c.cfg.ExternalID, false); err != nil { return c.release(err.Error()) }
    if c.held != "" && c.held != internal.Locator {
        if err = c.release("internal device changed"); err != nil { return err }
    }
    if c.held == "" {
        if err = c.backend.Grab(internal); err != nil { return fmt.Errorf("could not block internal keyboard: %w", err) }
        c.held = internal.Locator
    }
    c.State, c.Reason = "BLOCKED", "external keyboard present"
    return nil
}

func (c *Controller) Close() error { return c.release("shutdown") }
