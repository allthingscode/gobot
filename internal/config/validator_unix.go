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
		return fmt.Errorf("statfs %s: %w", root, err)
	}

	// Calculate available space in bytes
	bavail := uint64(stat.Bavail) //nolint:gosec // whyNoLint: G115: Bavail is non-negative
	bsize := uint64(stat.Bsize)   //nolint:gosec // whyNoLint: G115: Bsize is non-negative
	available := bavail * bsize
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
		return fmt.Errorf("stat %s: %w", path, err)
	}

	mode := info.Mode().Perm()
	// Warn if secrets directory is world-readable or group-writable/world-writable
	// (Check for any bits in 0044 or 0022)
	if mode&0o044 != 0 || mode&0o022 != 0 {
		result.Errors = append(result.Errors, ValidationError{
			Field:    "secrets.permissions",
			Message:  fmt.Sprintf("secrets directory has insecure permissions: %s", path),
			Remedy:   fmt.Sprintf("run 'chmod 700 %s' to restrict access", path),
			Severity: SeverityWarning,
		})
	}
	return nil
}
