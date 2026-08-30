unit uJsonCache;

interface

uses
  System.SysUtils, System.Generics.Collections, JsonDataObjects;

const
  JsonHashCacheLimit = 64;

type
  TJsonSessionCache = class
  private
    FRef: Integer;
    FMap: TDictionary<UInt64, TObject>;
    FLru: TList<TObject>;
    FUuid: TDictionary<string, TJsonBaseObject>;
    function HashOf(const AText: string): UInt64;
    procedure Touch(ASlot: TObject);
    procedure Evict(ASlot: TObject);
    procedure InsertSlot(AHash: UInt64; const AText: string; ATree: TJsonBaseObject);
    function NewKey: string;
    function AdoptTree(ATree: TJsonBaseObject): string;
  public
    constructor Create;
    destructor Destroy; override;
    procedure AddRef;
    function Release: Integer;
    function Ensure(const AText: string): TJsonBaseObject;
    procedure Rekey(const AOldText, ANewText: string; ATree: TJsonBaseObject);
    function Resolve(const AText: string): TJsonBaseObject;
    function TryUuid(const AText: string; out ATree: TJsonBaseObject): Boolean;
    function ParseNew(const AText: string): string;
    function CloneNew(const AText: string): string;
    function TakeTree(ATree: TJsonBaseObject): string;
    function NewEmpty(AArray: Boolean): string;
    function FreeKey(const AText: string): Boolean;
  end;

function IsJsonCacheKey(const AText: string): Boolean;
function JsonCacheAcquire(AGetInfo: TFunc<Integer, Pointer>;
  ASetInfo: TProc<Integer, Pointer>;
  AObtainCode: TFunc<Integer>): TJsonSessionCache;
function JsonCacheInfoCode: Integer;

implementation

uses
  System.SyncObjs, uJsonCore;

type
  TJsonHashSlot = class
    Hash: UInt64;
    Text: string;
    Tree: TJsonBaseObject;
    destructor Destroy; override;
  end;

var
  GLock: TCriticalSection;
  GInfoCode: Integer;

destructor TJsonHashSlot.Destroy;
begin
  Tree.Free;
  inherited;
end;

function IsJsonCacheKey(const AText: string): Boolean;
var
  I: Integer;
  C: Char;
begin
  Result := Length(AText) = 36;
  if not Result then
    Exit;
  for I := 1 to 36 do
  begin
    C := AText[I];
    if (I = 9) or (I = 14) or (I = 19) or (I = 24) then
    begin
      if C <> '-' then
        Exit(False);
    end
    else if not CharInSet(C, ['0'..'9', 'a'..'f', 'A'..'F']) then
      Exit(False);
  end;
end;

constructor TJsonSessionCache.Create;
begin
  inherited Create;
  FRef := 0;
  FMap := TDictionary<UInt64, TObject>.Create;
  FLru := TList<TObject>.Create;
  FUuid := TDictionary<string, TJsonBaseObject>.Create;
end;

destructor TJsonSessionCache.Destroy;
var
  I: Integer;
  Tree: TJsonBaseObject;
begin
  for Tree in FUuid.Values do
    Tree.Free;
  FUuid.Free;
  for I := 0 to FLru.Count - 1 do
    FLru[I].Free;
  FLru.Free;
  FMap.Free;
  inherited;
end;

procedure TJsonSessionCache.AddRef;
begin
  Inc(FRef);
end;

function TJsonSessionCache.Release: Integer;
begin
  Dec(FRef);
  Result := FRef;
end;

{$IFOPT Q+}
  {$DEFINE JSON_HASH_OVERFLOW_ON}
  {$Q-}
{$ENDIF}
function TJsonSessionCache.HashOf(const AText: string): UInt64;
const
  Offset = UInt64(14695981039346656037);
  Prime = UInt64(1099511628211);
var
  B: TBytes;
  I: Integer;
begin
  { FNV-1a: wrap on purpose; $Q+ would raise on every JSON text. }
  B := TEncoding.UTF8.GetBytes(AText);
  Result := Offset;
  for I := 0 to High(B) do
  begin
    Result := Result xor B[I];
    Result := Result * Prime;
  end;
end;
{$IFDEF JSON_HASH_OVERFLOW_ON}
  {$Q+}
  {$UNDEF JSON_HASH_OVERFLOW_ON}
{$ENDIF}

procedure TJsonSessionCache.Touch(ASlot: TObject);
var
  I: Integer;
begin
  I := FLru.IndexOf(ASlot);
  if (I >= 0) and (I <> FLru.Count - 1) then
  begin
    FLru.Delete(I);
    FLru.Add(ASlot);
  end;
end;

procedure TJsonSessionCache.Evict(ASlot: TObject);
begin
  FMap.Remove(TJsonHashSlot(ASlot).Hash);
  FLru.Remove(ASlot);
  ASlot.Free;
end;

procedure TJsonSessionCache.InsertSlot(AHash: UInt64; const AText: string;
  ATree: TJsonBaseObject);
var
  Slot: TJsonHashSlot;
  Existing: TObject;
begin
  if FMap.TryGetValue(AHash, Existing) then
    Evict(Existing);
  while FLru.Count >= JsonHashCacheLimit do
    Evict(FLru[0]);
  Slot := TJsonHashSlot.Create;
  Slot.Hash := AHash;
  Slot.Text := AText;
  Slot.Tree := ATree;
  FMap.Add(AHash, Slot);
  FLru.Add(Slot);
end;

function TJsonSessionCache.Ensure(const AText: string): TJsonBaseObject;
var
  H: UInt64;
  Obj: TObject;
  Slot: TJsonHashSlot;
begin
  H := HashOf(AText);
  if FMap.TryGetValue(H, Obj) then
  begin
    Slot := TJsonHashSlot(Obj);
    if Slot.Text = AText then
    begin
      Touch(Slot);
      Result := Slot.Tree;
      Exit;
    end;
    Evict(Slot);
  end;
  Result := JsonParseDoc(AText);
  InsertSlot(H, AText, Result);
end;

procedure TJsonSessionCache.Rekey(const AOldText, ANewText: string;
  ATree: TJsonBaseObject);
var
  HOld, HNew: UInt64;
  Obj, Other: TObject;
  Slot: TJsonHashSlot;
begin
  HOld := HashOf(AOldText);
  HNew := HashOf(ANewText);
  if FMap.TryGetValue(HOld, Obj) and (TJsonHashSlot(Obj).Tree = ATree) then
  begin
    Slot := TJsonHashSlot(Obj);
    if HOld = HNew then
    begin
      Slot.Text := ANewText;
      Touch(Slot);
      Exit;
    end;
    FMap.Remove(HOld);
    if FMap.TryGetValue(HNew, Other) and (Other <> Slot) then
      Evict(Other);
    Slot.Hash := HNew;
    Slot.Text := ANewText;
    FMap.Add(HNew, Slot);
    Touch(Slot);
  end
  else
    InsertSlot(HNew, ANewText, ATree);
end;

function TJsonSessionCache.NewKey: string;
var
  G: TGUID;
begin
  CreateGUID(G);
  Result := LowerCase(Copy(GUIDToString(G), 2, 36));
end;

function TJsonSessionCache.AdoptTree(ATree: TJsonBaseObject): string;
var
  Key: string;
  N: Integer;
begin
  try
    for N := 1 to 8 do
    begin
      Key := NewKey;
      if not FUuid.ContainsKey(Key) then
      begin
        FUuid.Add(Key, ATree);
        ATree := nil;
        Result := Key;
        Exit;
      end;
    end;
    raise EJsonUdr.Create('Failed to allocate JSON key');
  finally
    ATree.Free;
  end;
end;

function TJsonSessionCache.TryUuid(const AText: string;
  out ATree: TJsonBaseObject): Boolean;
begin
  ATree := nil;
  Result := IsJsonCacheKey(AText) and FUuid.TryGetValue(LowerCase(AText), ATree);
end;

function TJsonSessionCache.Resolve(const AText: string): TJsonBaseObject;
begin
  if IsJsonCacheKey(AText) then
  begin
    if not TryUuid(AText, Result) then
      raise EJsonUdr.Create('JSON key not found');
    Exit;
  end;
  Result := Ensure(AText);
end;

function TJsonSessionCache.ParseNew(const AText: string): string;
var
  CopyDoc: TJsonBaseObject;
begin
  if IsJsonCacheKey(AText) then
    raise EJsonUdr.Create('PARSE expects JSON text, not a cache key');
  CopyDoc := Ensure(AText).Clone;
  Result := AdoptTree(CopyDoc);
end;

function TJsonSessionCache.CloneNew(const AText: string): string;
begin
  Result := AdoptTree(Resolve(AText).Clone);
end;

function TJsonSessionCache.TakeTree(ATree: TJsonBaseObject): string;
begin
  Result := AdoptTree(ATree);
end;

function TJsonSessionCache.NewEmpty(AArray: Boolean): string;
begin
  if AArray then
    Result := AdoptTree(TJsonArray.Create)
  else
    Result := AdoptTree(TJsonObject.Create);
end;

function TJsonSessionCache.FreeKey(const AText: string): Boolean;
var
  Key: string;
  Tree: TJsonBaseObject;
begin
  Result := False;
  if not IsJsonCacheKey(AText) then
    Exit;
  Key := LowerCase(AText);
  if not FUuid.TryGetValue(Key, Tree) then
    Exit;
  FUuid.Remove(Key);
  Tree.Free;
  Result := True;
end;

function JsonCacheAcquire(AGetInfo: TFunc<Integer, Pointer>;
  ASetInfo: TProc<Integer, Pointer>;
  AObtainCode: TFunc<Integer>): TJsonSessionCache;
var
  P: Pointer;
begin
  GLock.Enter;
  try
    if GInfoCode = 0 then
      GInfoCode := AObtainCode();
    P := AGetInfo(GInfoCode);
    if P = nil then
    begin
      Result := TJsonSessionCache.Create;
      ASetInfo(GInfoCode, Result);
    end
    else
      Result := TJsonSessionCache(P);
    Result.AddRef;
  finally
    GLock.Leave;
  end;
end;

function JsonCacheInfoCode: Integer;
begin
  Result := GInfoCode;
end;

initialization
  GLock := TCriticalSection.Create;
  GInfoCode := 0;

finalization
  GLock.Free;

end.
