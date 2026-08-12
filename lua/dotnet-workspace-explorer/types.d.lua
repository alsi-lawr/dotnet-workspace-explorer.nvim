---@meta _

---@alias DweNodeId string
---@alias DweNodeKind
---| "workspace"
---| "solutionFolder"
---| "project"
---| "projectFolder"
---| "dependencyContainer"
---| "dependency"
---| "dependencyProperty"
---| "solutionItem"
---| "projectFile"
---| "directory"
---| "file"

---@alias DweWorkspacePhase "idle"|"loading"|"ready"|"failed"|"stopped"
---@alias DweCommandExecution "transaction"|"operation"
---@alias DweSelectorAvailability "available"|"alreadyPresent"|"ineligible"
---@alias DweSelectorEntryKind "directory"|"file"
---@alias DweGitState "staged"|"unstaged"|"renamed"|"deleted"|"unmerged"|"untracked"|"ignored"
---@alias DweEditMode "move"|"copy"

---@class DweProblem
---@field code? string
---@field message string
---@field data? unknown

---@class DweProtocolVersion
---@field major integer
---@field minor integer

---@class DweWorkspaceIdentity
---@field id string
---@field revision integer

---@class DweRpcLimits
---@field maxFrameBytes integer
---@field maxPageSize integer

---@class DweInitializeResult
---@field protocolVersion DweProtocolVersion
---@field workspace DweWorkspaceIdentity
---@field capabilities string[]
---@field limits DweRpcLimits

---@class DweNode
---@field id DweNodeId
---@field parent_id? DweNodeId
---@field kind DweNodeKind
---@field name string
---@field load_state string
---@field capabilities string[]
---@field revision integer
---@field icon_hint? string

---@class DweWorkspaceOptions
---@field command string
---@field target string
---@field spawn? function
---@field max_page_size? integer
---@field on_change? fun(workspace: DweWorkspaceTree)
---@field on_error? fun(problem: DweProblem)
---@field on_notification? fun(method: string, parameters: table)
---@field git_enabled? boolean

---@class DweWorkspaceCapture
---@field generation integer
---@field epoch integer
---@field workspace string
---@field owner? DweExpansionOwner
---@field owner_loss_invalidates? boolean

---@class DweWorkspaceSnapshot
---@field nodes table<DweNodeId, DweNode>
---@field children table<DweNodeId, DweNodeId[]>
---@field roots DweNodeId[]
---@field expanded table<DweNodeId, boolean>
---@field desired_expanded? table<DweNodeId, boolean>
---@field previous_nodes? table<DweNodeId, DweNode>
---@field revision integer
---@field selected_id? DweNodeId

---@class DweExpansionStage
---@field token integer
---@field parent_id DweNodeId
---@field generation integer
---@field epoch integer
---@field workspace_id string
---@field base_revision integer
---@field page_revision? integer
---@field next_token? string
---@field seen_tokens table<string, boolean>
---@field nodes table<DweNodeId, DweNode>
---@field ids DweNodeId[]
---@field waiters DweExpansionWaiter[]
---@field previous_expanded? boolean
---@field complete boolean
---@field awaiting_delta boolean
---@field settled boolean

---@class DweExpansionOwner
---@field kind "whole_tree"
---@field token integer
---@field cancel? fun(problem: DweProblem)
---@field retry? fun()
---@field overlay? DweWorkspaceSnapshot

---@class DwePresentationMetadata
---@field loading boolean
---@field provisional boolean
---@field actionable boolean
---@field parent_id? DweNodeId

---@class DweRpcWorkspace
---@field id string
---@field revision integer

---@class DweRpcClient
---@field generation integer
---@field inert? boolean
---@field state "new"|"starting"|"ready"|"failed"|"stopped"
---@field capabilities table<string, boolean>
---@field limits? DweRpcLimits
---@field workspace? DweRpcWorkspace
---@field request fun(self: DweRpcClient, method: string, parameters?: table, callback?: DweErrorFirstCallback): integer?
---@field start fun(self: DweRpcClient, callback: DweErrorFirstCallback)
---@field stop fun(self: DweRpcClient, reason?: string, force?: boolean)
---@field has_capability fun(self: DweRpcClient, name: string): boolean

---@class DweWorkspaceTree
---@field nodes table<DweNodeId, DweNode>
---@field children table<DweNodeId, DweNodeId[]>
---@field loading table<DweNodeId, DweExpansionWaiter[]>
---@field stages table<DweNodeId, DweExpansionStage>
---@field next_expansion_token integer
---@field expansion_owner? DweExpansionOwner
---@field roots DweNodeId[]
---@field expanded table<DweNodeId, boolean>
---@field selected_id? DweNodeId
---@field revision integer
---@field reflected_base_revision? integer
---@field workspace_id string
---@field phase DweWorkspacePhase
---@field decorations table<DweNodeId, DweGitState[]>
---@field marks table<DweNodeId, boolean>
---@field mark_mode? DweEditMode
---@field epoch integer
---@field reconcile_waiters DweWorkspaceCallback[]
---@field reconciling boolean
---@field reconcile_queued boolean
---@field reconciliation_deferred boolean
---@field deferred_reconciliation boolean
---@field git_enabled boolean
---@field client DweRpcClient
---@field on_change fun(workspace: DweWorkspaceTree)
---@field on_error fun(problem: DweProblem)
---@field on_notification fun(method: string, parameters: table)
---@field _delta table

---@class DweCommandParameter
---@field id string
---@field name string
---@field type string
---@field required boolean

---@class DweCommandDescriptor
---@field id string
---@field name string
---@field access "read"|"write"
---@field parameters DweCommandParameter[]
---@field targetKinds DweNodeKind[]

---@class DweCommandDescribeResult
---@field command DweCommandDescriptor

---@class DweCommandEffect
---@field operation string
---@field target string
---@field recursive boolean

---@class DweCommandPreview
---@field confirmationToken string
---@field expiresAtUtc string
---@field summary string
---@field effects DweCommandEffect[]

---@class DweCommandRequest
---@field commandId string
---@field targetNodeId DweNodeId
---@field arguments table
---@field expectedRevision integer
---@field confirmationToken? string

---@class DweAppliedResult
---@field applied true
---@field revision integer

---@class DweOperationResult
---@field operationId string
---@field revision integer

---@class DwePendingOperation
---@field operation_id string
---@field revision integer
---@field workspace_id string

---@class DweOperationDiagnostic
---@field workspaceId string
---@field revision integer
---@field severity string
---@field code string
---@field message string
---@field retryable boolean

---@class DweOperationCompletion
---@field workspaceId string
---@field operationId string
---@field sequence integer
---@field revision integer
---@field outcome "succeeded"|"cancelled"|"failed"
---@field diagnostics DweOperationDiagnostic[]

---@class DweCreationOption
---@field selectionId string
---@field kind "empty"|"itemTemplate"|"projectTemplate"|"solutionFolder"|"addExisting"
---@field displayName string
---@field description string
---@field execution DweCommandExecution
---@field language? string

---@class DweCreationOptionsResult
---@field revision integer
---@field options DweCreationOption[]

---@class DweSelectorStartOptions
---@field selection_id string
---@field target_id DweNodeId
---@field target_kind DweNodeKind
---@field revision integer

---@class DweSelectorEntry
---@field id string
---@field parent_id? string
---@field kind DweSelectorEntryKind
---@field name string
---@field expandable boolean
---@field selectable boolean
---@field icon_hint? string
---@field availability DweSelectorAvailability
---@field git_states DweGitState[]

---@class DweHighlightSpan
---@field group string
---@field start integer
---@field finish integer

---@class DweSign
---@field text string
---@field group string

---@class DweRenderRow
---@field id string
---@field depth integer
---@field ancestors string[]
---@field highlights DweHighlightSpan[]
---@field sign? DweSign
---@field loading boolean
---@field provisional boolean
---@field actionable boolean
---@field parent_id? DweNodeId

---@class DweViewSnapshot
---@field selected? string
---@field ancestors string[]
---@field focus integer
---@field saved? table
---@field anchor? { id: string, offset: integer }
---@field width? integer
---@field mappings? table<string, table|false>

---@class DweGlyphConfig
---@field closed string
---@field open string
---@field leaf string
---@field solution string
---@field project string
---@field folder string
---@field file string

---@class DwePresentationConfig
---@field devicons boolean

---@class DweGitConfig
---@field enable boolean

---@class DweMappingsConfig
---@field activate string|false
---@field close string|false
---@field collapse string|false
---@field collapse_all string|false
---@field delete string|false
---@field edit string|false
---@field expand string|false
---@field expand_all string|false
---@field git_refresh string|false
---@field clear_marks string|false
---@field mark_copy string|false
---@field mark_move string|false
---@field new string|false
---@field packages string|false
---@field place string|false
---@field refresh string|false
---@field rename string|false

---@class DweConfig
---@field command string
---@field package_command string
---@field target fun(): string
---@field position "left"|"right"
---@field presentation DwePresentationConfig
---@field git DweGitConfig
---@field width integer
---@field glyphs DweGlyphConfig
---@field mappings DweMappingsConfig|false

---@class DweConfigInput
---@field command? string
---@field package_command? string
---@field target? fun(): string
---@field position? "left"|"right"
---@field presentation? table
---@field git? table
---@field width? integer
---@field glyphs? table
---@field mappings? table|false

---@alias DweErrorFirstCallback fun(error: DweProblem?, result: unknown?)
---@alias DweWorkspaceCallback fun(error: DweProblem?, result: DweWorkspaceTree?)
---@alias DweExpansionWaiter fun(error: DweProblem?, result: DweNodeId[]?)
---@alias DweBooleanCallback fun(value: boolean)
