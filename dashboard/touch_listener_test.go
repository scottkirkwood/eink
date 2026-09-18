package main

import (
	"testing"
)

func TestTranslateCoordinates(t *testing.T) {
	tests := []struct {
		name      string
		hwX, hwY  int
		rotation  int
		wantX     int
		wantY     int
	}{
		{
			name:     "Rotation 0 (Native Portrait)",
			hwX:      100,
			hwY:      200,
			rotation: 0,
			wantX:    100,
			wantY:    200,
		},
		{
			name:     "Rotation 90 Top-Left of Landscape (hwX=1071, hwY=0)",
			hwX:      1071,
			hwY:      0,
			rotation: 90,
			wantX:    0,
			wantY:    0,
		},
		{
			name:     "Rotation 90 Bottom-Right of Landscape (hwX=0, hwY=1447)",
			hwX:      0,
			hwY:      1447,
			rotation: 90,
			wantX:    1447,
			wantY:    1071,
		},
		{
			name:     "Rotation 90 Center (hwX=535, hwY=724)",
			hwX:      535,
			hwY:      724,
			rotation: 90,
			wantX:    724,
			wantY:    536,
		},
		{
			name:     "Rotation 270 Top-Left of Landscape (hwX=0, hwY=1447)",
			hwX:      0,
			hwY:      1447,
			rotation: 270,
			wantX:    0,
			wantY:    0,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			gotX, gotY := translateCoordinates(tt.hwX, tt.hwY, tt.rotation)
			if gotX != tt.wantX || gotY != tt.wantY {
				t.Errorf("translateCoordinates(%d, %d, %d) = (%d, %d), want (%d, %d)",
					tt.hwX, tt.hwY, tt.rotation, gotX, gotY, tt.wantX, tt.wantY)
			}
		})
	}
}

func TestTaskHitTesting(t *testing.T) {
	// Formula: (landY - 524) / 74
	tests := []struct {
		name      string
		landY     int
		wantIndex int
	}{
		{"Task 0 top edge", 524, 0},
		{"Task 0 middle", 555, 0},
		{"Task 0 bottom", 589, 0},
		{"Task 1 top edge", 598, 1},
		{"Task 1 middle", 631, 1},
		{"Task 2 middle", 705, 2},
		{"Task 3 middle", 779, 3},
		{"Task 4 middle", 853, 4},
		{"Task 5 middle", 927, 5},
		{"Task 5 bottom", 960, 5},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := (tt.landY - 524) / 74
			if got != tt.wantIndex {
				t.Errorf("Hit test for Y=%d gave %d, want %d", tt.landY, got, tt.wantIndex)
			}
		})
	}
}
