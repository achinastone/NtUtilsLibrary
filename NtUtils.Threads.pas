unit NtUtils.Threads;

interface

uses
  Winapi.WinNt, Ntapi.ntdef, Ntapi.ntpsapi, Ntapi.ntrtl, NtUtils.Exceptions;

const
  // Ntapi.ntpsapi
  NtCurrentThread: THandle = THandle(-2);

// Open a thread (always succeeds for the current PID)
function NtxOpenThread(out hThread: THandle; TID: NativeUInt;
  DesiredAccess: TAccessMask; HandleAttributes: Cardinal = 0): TNtxStatus;

// Reopen a handle to the current thread with the specific access
function NtxOpenCurrentThread(out hThread: THandle;
  DesiredAccess: TAccessMask; HandleAttributes: Cardinal = 0): TNtxStatus;

// Query variable-size information
function NtxQueryThread(hThread: THandle; InfoClass: TThreadInfoClass;
  out Status: TNtxStatus): Pointer;

// Set variable-size information
function NtxSetThread(hThread: THandle; InfoClass: TThreadInfoClass;
  Data: Pointer; DataSize: Cardinal): TNtxStatus;

type
  NtxThread = class
    // Query fixed-size information
    class function Query<T>(hThread: THandle;
      InfoClass: TThreadInfoClass; out Buffer: T): TNtxStatus; static;

    // Set fixed-size information
    class function SetInfo<T>(hThread: THandle;
      InfoClass: TThreadInfoClass; const Buffer: T): TNtxStatus; static;
  end;

// Query exit status of a thread
function NtxQueryExitStatusThread(hThread: THandle; out ExitStatus: NTSTATUS)
  : TNtxStatus;

// Get thread context
function NtxGetContextThread(hThread: THandle; FlagsToQuery: Cardinal;
  out Context: TContext): TNtxStatus;

// Set thread context
function NtxSetContextThread(hThread: THandle; const Context: TContext):
  TNtxStatus;

// Create a thread in a process
function NtxCreateThread(out hThread: THandle; hProcess: THandle; StartRoutine:
  TUserThreadStartRoutine; Argument: Pointer; CreateFlags: Cardinal = 0;
  ZeroBits: NativeUInt = 0; StackSize: NativeUInt = 0; MaxStackSize:
  NativeUInt = 0; HandleAttributes: Cardinal = 0): TNtxStatus;

// Create a thread in a process
function RtlxCreateThread(out hThread: THandle; hProcess: THandle;
  StartRoutine: TUserThreadStartRoutine; Parameter: Pointer;
  CreateSuspended: Boolean = False): TNtxStatus;

implementation

uses
  Ntapi.ntstatus, Ntapi.ntobapi, Ntapi.ntseapi,
  NtUtils.Access.Expected;

function NtxOpenThread(out hThread: THandle; TID: NativeUInt;
  DesiredAccess: TAccessMask; HandleAttributes: Cardinal = 0): TNtxStatus;
var
  ClientId: TClientId;
  ObjAttr: TObjectAttributes;
begin
  if TID = NtCurrentThreadId then
  begin
    hThread := NtCurrentThread;
    Result.Status := STATUS_SUCCESS;
  end
  else
  begin
    InitializeObjectAttributes(ObjAttr, nil, HandleAttributes);
    ClientId.Create(0, TID);

    Result.Location := 'NtOpenThread';
    Result.LastCall.CallType := lcOpenCall;
    Result.LastCall.AccessMask := DesiredAccess;
    Result.LastCall.AccessMaskType := @ThreadAccessType;

    Result.Status := NtOpenThread(hThread, DesiredAccess, ObjAttr, ClientId);
  end;
end;

function NtxOpenCurrentThread(out hThread: THandle;
  DesiredAccess: TAccessMask; HandleAttributes: Cardinal): TNtxStatus;
var
  Flags: Cardinal;
begin
  // Duplicating the pseudo-handle is more reliable then opening thread by TID

  if DesiredAccess = MAXIMUM_ALLOWED then
  begin
    Flags := DUPLICATE_SAME_ACCESS;
    DesiredAccess := 0;
  end
  else
    Flags := 0;

  Result.Location := 'NtDuplicateObject';
  Result.Status := NtDuplicateObject(NtCurrentProcess, NtCurrentThread,
    NtCurrentProcess, hThread, DesiredAccess, HandleAttributes, Flags);
end;

function NtxQueryThread(hThread: THandle; InfoClass: TThreadInfoClass;
  out Status: TNtxStatus): Pointer;
var
  BufferSize, Required: Cardinal;
begin
  Status.Location := 'NtQueryInformationThread';
  Status.LastCall.CallType := lcQuerySetCall;
  Status.LastCall.InfoClass := Cardinal(InfoClass);
  Status.LastCall.InfoClassType := TypeInfo(TThreadInfoClass);
  RtlxComputeThreadQueryAccess(Status.LastCall, InfoClass);

  BufferSize := 0;
  repeat
    Result := AllocMem(BufferSize);

    Required := 0;
    Status.Status := NtQueryInformationThread(hThread, InfoClass, Result,
      BufferSize, @Required);

    if not Status.IsSuccess then
    begin
      FreeMem(Result);
      Result := nil;
    end;
  until not NtxExpandBuffer(Status, BufferSize, Required);
end;

function NtxSetThread(hThread: THandle; InfoClass: TThreadInfoClass;
  Data: Pointer; DataSize: Cardinal): TNtxStatus;
begin
  Result.Location := 'NtSetInformationThread';
  Result.LastCall.CallType := lcQuerySetCall;
  Result.LastCall.InfoClass := Cardinal(InfoClass);
  Result.LastCall.InfoClassType := TypeInfo(TThreadInfoClass);
  RtlxComputeThreadSetAccess(Result.LastCall, InfoClass);

  Result.Status := NtSetInformationThread(hThread, InfoClass, Data, DataSize);
end;

class function NtxThread.Query<T>(hThread: THandle;
  InfoClass: TThreadInfoClass; out Buffer: T): TNtxStatus;
begin
  Result.Location := 'NtQueryInformationThread';
  Result.LastCall.CallType := lcQuerySetCall;
  Result.LastCall.InfoClass := Cardinal(InfoClass);
  Result.LastCall.InfoClassType := TypeInfo(TThreadInfoClass);
  RtlxComputeThreadQueryAccess(Result.LastCall, InfoClass);

  Result.Status := NtQueryInformationThread(hThread, InfoClass, @Buffer,
    SizeOf(Buffer), nil);
end;

class function NtxThread.SetInfo<T>(hThread: THandle;
  InfoClass: TThreadInfoClass; const Buffer: T): TNtxStatus;
begin
  Result := NtxSetThread(hThread, InfoClass, @Buffer, SizeOf(Buffer));
end;

function NtxQueryExitStatusThread(hThread: THandle; out ExitStatus: NTSTATUS)
  : TNtxStatus;
var
  Info: TThreadBasicInformation;
begin
  Result := NtxThread.Query<TThreadBasicInformation>(hThread,
    ThreadBasicInformation, Info);

  if Result.IsSuccess then
    ExitStatus := Info.ExitStatus;
end;

function NtxGetContextThread(hThread: THandle; FlagsToQuery: Cardinal;
  out Context: TContext): TNtxStatus;
begin
  FillChar(Context, SizeOf(Context), 0);
  Context.ContextFlags := FlagsToQuery;

  Result.Location := 'NtGetContextThread';
  Result.LastCall.Expects(THREAD_GET_CONTEXT, @ThreadAccessType);
  Result.Status := NtGetContextThread(hThread, Context);
end;

function NtxSetContextThread(hThread: THandle; const Context: TContext):
  TNtxStatus;
begin
  Result.Location := 'NtSetContextThread';
  Result.LastCall.Expects(THREAD_SET_CONTEXT, @ThreadAccessType);
  Result.Status := NtSetContextThread(hThread, Context);
end;

function NtxCreateThread(out hThread: THandle; hProcess: THandle; StartRoutine:
  TUserThreadStartRoutine; Argument: Pointer; CreateFlags: Cardinal; ZeroBits:
  NativeUInt; StackSize: NativeUInt; MaxStackSize: NativeUInt; HandleAttributes:
  Cardinal): TNtxStatus;
var
  ObjAttr: TObjectAttributes;
begin
  InitializeObjectAttributes(ObjAttr, nil, HandleAttributes);

  Result.Location := 'NtCreateThreadEx';
  Result.LastCall.Expects(PROCESS_CREATE_THREAD, @ProcessAccessType);

  Result.Status := NtCreateThreadEx(hThread, THREAD_ALL_ACCESS, @ObjAttr,
    hProcess, StartRoutine, Argument, CreateFlags, ZeroBits, StackSize,
    MaxStackSize, nil);
end;

function RtlxCreateThread(out hThread: THandle; hProcess: THandle;
  StartRoutine: TUserThreadStartRoutine; Parameter: Pointer;
  CreateSuspended: Boolean): TNtxStatus;
begin
  Result.Location := 'RtlCreateUserThread';
  Result.LastCall.Expects(PROCESS_CREATE_THREAD, @ProcessAccessType);

  Result.Status := RtlCreateUserThread(hProcess, nil, CreateSuspended, 0, 0, 0,
    StartRoutine, Parameter, hThread, nil);
end;

end.
