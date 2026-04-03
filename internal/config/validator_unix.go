//go:build !windows

package config

import (
	"fmt"
	"syscall"
)

func (v *Validator) checkDiskSpace(root string, result *ValidationResult) error {
	var stat syscall.Statfs_t
	if err := syscall.Statfs(root, &stat); err != nil {
		return err
	}
	
	// Calculate available space in bytes
	available := stat.Bavail * uint64(stat.Bsize)
	const minFree = 1 << 30 // 1GB in bytes
	
	if available < minFree {
		result.Errors = append(result.Errors, ValidationError{
			Field:    "disk_space",
			Message:  fmt.Sprintf("low disk space: %.2f GB free (minimum 1GB recommended)", float64(available)/(1<<30)),
			Remedy:   "free up disk space or move storage_root to a different drive",
			Severity: SeverityWarning,
		})
	}
	return nil
}
