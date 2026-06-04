package main

import (
	"testing"
	"time"
)

func newTestDecider() *Decider {
	cfg := Config{
		HighThreshold:   80,
		LowThreshold:    70,
		TriggerCount:    3,
		CooldownSeconds: 600,
		PerNodeCooldown: 300 * time.Second,
	}
	return &Decider{cfg: cfg, states: map[string]*nodeState{}}
}

// 序列:连续高位 → 触发 cordon → 持续低位 → 自动 uncordon
func TestStateMachine_CordonThenUncordon(t *testing.T) {
	d := newTestDecider()
	node := "n1"
	now := time.Now()

	steps := []struct {
		cpu, mem    float64
		cordoned    bool
		managed     bool
		dtSec       int
		wantAction  Action
		wantReason  string
		description string
	}{
		// 高位连续 3 次才触发(序列 82, 85, 90)
		{82, 50, false, false, 0, ActionNone, "", "1st over"},
		{85, 50, false, false, 30, ActionNone, "", "2nd over"},
		{90, 50, false, false, 30, ActionCordon, "cpu-high", "3rd over → cordon"},

		// 状态机假设外层已 cordon 并打 annotation
		// 立即一次低位:不会立刻 uncordon,要等 cooldown
		{60, 50, true, true, 30, ActionNone, "", "below but cooldown not met"},
		{60, 50, true, true, 300, ActionNone, "", "still cooling"},
		{60, 50, true, true, 600, ActionUncordon, "below-low-sustained", "uncordon"},
	}

	for i, s := range steps {
		now = now.Add(time.Duration(s.dtSec) * time.Second)
		u := NodeUsage{CPUPercent: s.cpu, MemPercent: s.mem}
		act, reason := d.Decide(node, u, s.cordoned, s.managed, now)
		if act != s.wantAction {
			t.Errorf("step %d (%s): action=%v want=%v", i, s.description, act, s.wantAction)
		}
		if s.wantReason != "" && reason != s.wantReason {
			t.Errorf("step %d (%s): reason=%q want=%q", i, s.description, reason, s.wantReason)
		}
	}
}

// 中间一次低于阈值 → 计数清零 → 不该触发
func TestStateMachine_FlapResetsCounter(t *testing.T) {
	d := newTestDecider()
	now := time.Now()
	seq := []float64{82, 85, 50, 82, 85} // 第3次回落,计数清零;后续2次不够3次
	for i, c := range seq {
		now = now.Add(30 * time.Second)
		act, _ := d.Decide("n1", NodeUsage{CPUPercent: c, MemPercent: 30}, false, false, now)
		if act != ActionNone {
			t.Errorf("step %d cpu=%.0f: action=%v want=ActionNone", i, c, act)
		}
	}
}

// 内存高也应该触发
func TestStateMachine_MemHigh(t *testing.T) {
	d := newTestDecider()
	now := time.Now()
	for i := 0; i < 3; i++ {
		now = now.Add(30 * time.Second)
		act, reason := d.Decide("n2", NodeUsage{CPUPercent: 10, MemPercent: 90}, false, false, now)
		if i < 2 {
			if act != ActionNone {
				t.Fatalf("step %d: want none got %v", i, act)
			}
			continue
		}
		if act != ActionCordon {
			t.Fatalf("3rd step: want cordon got %v", act)
		}
		if reason != "mem-high" {
			t.Fatalf("reason=%q want mem-high", reason)
		}
	}
}

// 手动 cordon(managed=false) 的节点不该被自动 uncordon
func TestStateMachine_RespectManualCordon(t *testing.T) {
	d := newTestDecider()
	now := time.Now()
	// 即使指标很低,只要 managed=false,就不动
	for i := 0; i < 30; i++ {
		now = now.Add(60 * time.Second)
		act, _ := d.Decide("n3", NodeUsage{CPUPercent: 10, MemPercent: 10}, true, false, now)
		if act != ActionNone {
			t.Fatalf("step %d: action=%v want none (manual cordon must be untouched)", i, act)
		}
	}
}

// 自动 uncordon 后冷却期内不该立刻再次 cordon
func TestStateMachine_PerNodeCooldown(t *testing.T) {
	d := newTestDecider()
	now := time.Now()
	// 先触发一次 cordon
	for i := 0; i < 3; i++ {
		now = now.Add(30 * time.Second)
		d.Decide("n4", NodeUsage{CPUPercent: 90, MemPercent: 30}, false, false, now)
	}
	// 立刻又收到 3 次高位采样(外层假装已 uncordon),但还在每节点冷却期内
	for i := 0; i < 3; i++ {
		now = now.Add(30 * time.Second)
		act, reason := d.Decide("n4", NodeUsage{CPUPercent: 90, MemPercent: 30}, false, false, now)
		if i < 2 {
			continue
		}
		if act != ActionNone || reason != "per-node-cooldown" {
			t.Fatalf("re-cordon during cooldown: act=%v reason=%q (want none/per-node-cooldown)", act, reason)
		}
	}
	// 跨过冷却期(300s)后应能再次触发
	now = now.Add(400 * time.Second)
	for i := 0; i < 3; i++ {
		now = now.Add(30 * time.Second)
		act, _ := d.Decide("n4", NodeUsage{CPUPercent: 90, MemPercent: 30}, false, false, now)
		if i < 2 {
			continue
		}
		if act != ActionCordon {
			t.Fatalf("after cooldown, should re-cordon, got %v", act)
		}
	}
}
