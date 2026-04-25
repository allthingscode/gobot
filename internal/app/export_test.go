package app

import (
	"context"
	"time"

	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/cron"
	"github.com/allthingscode/gobot/internal/memory"
	"github.com/allthingscode/gobot/internal/provider"
)

// Export unexported methods for testing.
func (h *DispatchHandler) IndexMemory(sessionKey, userMsg, assistantReply string) {
	h.indexMemory(sessionKey, userMsg, assistantReply)
}

func (h *DispatchHandler) MaybeHandleAdminCommand(sessionKey, text string) (string, bool) {
	return h.maybeHandleAdminCommand(sessionKey, text)
}

func (cd *CronDispatcher) HandleSystemJob(ctx context.Context, p cron.Payload) bool {
	return cd.handleSystemJob(ctx, p)
}

func (cd *CronDispatcher) SendSpecialistResponse(ctx context.Context, p cron.Payload, channel, to, reply string) {
	cd.sendSpecialistResponse(ctx, p, channel, to, reply)
}

func (hb *HeartbeatRunner) HeartbeatCheck(ctx context.Context) {
	hb.check(ctx)
}

func (a *TgAPI) IsDuplicate(key string) bool {
	return a.isDuplicate(key)
}

func (r *AgentRunner) ExecuteSingleToolCall(ctx context.Context, sessionKey, userID, toolName string, args map[string]any, iter, total int) (string, error) {
	return r.executeSingleToolCall(ctx, sessionKey, userID, toolName, args, iter, total)
}

// Hooks.
func SetUserHomeDir(f func() (string, error)) func() (string, error) {
	old := userHomeDir
	userHomeDir = f
	return old
}

// Unexported constructors and helpers.
func NewSpawnTool(prov provider.Provider, model string, specialistPrompts, specialistModels map[string]string, memStore *memory.MemoryStore, cfg *config.Config) *SpawnTool {
	return newSpawnTool(prov, model, specialistPrompts, specialistModels, memStore, cfg)
}

func NewShellExecTool(storageRoot string, timeout time.Duration, registry *ToolRegistry) Tool {
	return newShellExecTool(storageRoot, timeout, registry)
}

func NewListCalendarTool(storageRoot string) Tool {
	return newListCalendarTool(storageRoot)
}

func NewListTasksTool(storageRoot string) Tool {
	return newListTasksTool(storageRoot)
}

func NewCreateTaskTool(storageRoot string) Tool {
	return newCreateTaskTool(storageRoot)
}

func LoadPrivateFile(cfg *config.Config, name string) string {
	return loadPrivateFile(cfg, name)
}

func ResolveEmailSubject(p cron.Payload) string {
	return resolveEmailSubject(p)
}

func ValidateRunPrerequisites(cfg *config.Config) error {
	return validateRunPrerequisites(cfg)
}
