<!-- prompt_version: reviewer_prompt-v9 -->
Reviewer: {task_id}

## Post-Rebase Verification (F-098)

If the handoff indicates this is a post-rebase review:

1. **Verify Clean Merge**: Confirm that the Architect resolved all conflicts from conflict_report.json.
2. **Full Regression Check**: Since a rebase involves changing the base of the branch, pay extra attention to any semantic conflicts that git might have missed.
3. **Check rebase_count**: If rebase_count is 3 or more, and conflicts persist, flag for human escalation.
