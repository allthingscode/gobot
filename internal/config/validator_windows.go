//go:build windows

package config

import (
	"fmt"
	"golang.org/x/sys/windows"
)

func (v *Validator) checkDiskSpace(root string, result *ValidationResult) error {
	var freeBytes, totalBytes, totalFreeBytes uint64
	ptr, err := windows.UTF16PtrFromString(root)
	if err != nil {
		return err
	}
	err = windows.GetDiskFreeSpaceEx(ptr, &freeBytes, &totalBytes, &totalFreeBytes)
	if err != nil {
		return err
	}
	
	available := freeBytes
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
