//go:build !windows

package config

import (
	"fmt"
	"os"
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

func (v *Validator) checkPathPermissions(path string, result *ValidationResult) error {
	info, err := os.Stat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil // Directory doesn't exist yet, skip
		}
		return err
	}

	mode := info.Mode().Perm()
	// Warn if secrets directory is world-readable or group-writable/world-writable
	// (Check for any bits in 0044 or 0022)
	if mode&0044 != 0 || mode&0022 != 0 {
		result.Errors = append(result.Errors, ValidationError{
			Field:    "secrets.permissions",
			Message:  fmt.Sprintf("secrets directory has insecure permissions: %s", path),
			Remedy:   fmt.Sprintf("run 'chmod 700 %s' to restrict access", path),
			Severity: SeverityWarning,
		})
	}
	return nil
}
