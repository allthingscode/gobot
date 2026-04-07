//go:build windows

package secrets

import (
	"fmt"
	"unsafe"

	"golang.org/x/sys/windows"
)

// protect encrypts plaintext using Windows DPAPI (current-user scope).
func protect(plaintext []byte) ([]byte, error) {
	var dataIn windows.DataBlob
	if len(plaintext) > 0 {
		if len(plaintext) > 1<<31-1 {
			return nil, fmt.Errorf("plaintext too large")
		}
		dataIn.Size = uint32(len(plaintext)) // #nosec G115
		dataIn.Data = &plaintext[0]
	}
	var dataOut windows.DataBlob
	if err := windows.CryptProtectData(&dataIn, nil, nil, 0, nil, 0, &dataOut); err != nil {
		return nil, fmt.Errorf("CryptProtectData: %w", err)
	}
	defer func() { _, _ = windows.LocalFree(windows.Handle(unsafe.Pointer(dataOut.Data))) }()
	result := make([]byte, dataOut.Size)
	copy(result, unsafe.Slice(dataOut.Data, dataOut.Size))
	return result, nil
}

// unprotect decrypts DPAPI-encrypted ciphertext.
func unprotect(ciphertext []byte) ([]byte, error) {
	var dataIn windows.DataBlob
	if len(ciphertext) > 0 {
		if len(ciphertext) > 1<<31-1 {
			return nil, fmt.Errorf("ciphertext too large")
		}
		dataIn.Size = uint32(len(ciphertext)) // #nosec G115
		dataIn.Data = &ciphertext[0]
	}
	var dataOut windows.DataBlob
	if err := windows.CryptUnprotectData(&dataIn, nil, nil, 0, nil, 0, &dataOut); err != nil {
		return nil, fmt.Errorf("CryptUnprotectData: %w", err)
	}
	defer func() { _, _ = windows.LocalFree(windows.Handle(unsafe.Pointer(dataOut.Data))) }()
	result := make([]byte, dataOut.Size)
	copy(result, unsafe.Slice(dataOut.Data, dataOut.Size))
	return result, nil
}
