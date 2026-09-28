unit uJsonCore;

interface

uses
  System.SysUtils, System.Generics.Collections, JsonDataObjects;

type
  EJsonUdr = class(Exception);

  TJsonNodeRow = record
    AbsIdx: Integer;
    LocIdx: Integer;
    Name: string;
    Path: string;
    Typ: string;
    Val: string;
  end;

function JsonParseDoc(const AText: string): TJsonBaseObject;
function JsonParseLiteral(const AText: string): TJsonObject;

function JsonGetS(ADoc: TJsonBaseObject; const APath: string; out AValue: string): Boolean;
function JsonGetI(ADoc: TJsonBaseObject; const APath: string; out AValue: Integer): Boolean;
function JsonGetL(ADoc: TJsonBaseObject; const APath: string; out AValue: Int64): Boolean;
function JsonGetF(ADoc: TJsonBaseObject; const APath: string; out AValue: Double): Boolean;
function JsonGetB(ADoc: TJsonBaseObject; const APath: string; out AValue: Boolean): Boolean;
function JsonGetD(ADoc: TJsonBaseObject; const APath: string; out AValue: TDateTime): Boolean;
function JsonGetNode(ADoc: TJsonBaseObject; const APath: string; ACompact: Boolean;
  out AJson: string): Boolean;
function JsonGetTypeName(ADoc: TJsonBaseObject; const APath: string; out AName: string): Boolean;
function JsonExists(ADoc: TJsonBaseObject; const APath: string): Boolean;
function JsonIsNull(ADoc: TJsonBaseObject; const APath: string): Boolean;
function JsonCount(ADoc: TJsonBaseObject; const APath: string; out ACount: Integer): Boolean;

procedure JsonSetS(ADoc: TJsonBaseObject; const APath, AValue: string);
procedure JsonSetI(ADoc: TJsonBaseObject; const APath: string; AValue: Integer);
procedure JsonSetL(ADoc: TJsonBaseObject; const APath: string; AValue: Int64);
procedure JsonSetF(ADoc: TJsonBaseObject; const APath: string; AValue: Double);
procedure JsonSetB(ADoc: TJsonBaseObject; const APath: string; AValue: Boolean);
procedure JsonSetD(ADoc: TJsonBaseObject; const APath: string; AValue: TDateTime);
procedure JsonSetNull(ADoc: TJsonBaseObject; const APath: string);
procedure JsonSetJson(ADoc: TJsonBaseObject; const APath, AJsonValue: string);
procedure JsonSetNode(ADoc: TJsonBaseObject; const APath: string; ASrc: TJsonBaseObject);

procedure JsonRemove(ADoc: TJsonBaseObject; const APath: string);

procedure JsonAddS(ADoc: TJsonBaseObject; const APath, AValue: string);
procedure JsonAddI(ADoc: TJsonBaseObject; const APath: string; AValue: Integer);
procedure JsonAddL(ADoc: TJsonBaseObject; const APath: string; AValue: Int64);
procedure JsonAddF(ADoc: TJsonBaseObject; const APath: string; AValue: Double);
procedure JsonAddB(ADoc: TJsonBaseObject; const APath: string; AValue: Boolean);
procedure JsonAddD(ADoc: TJsonBaseObject; const APath: string; AValue: TDateTime);
procedure JsonAddA(ADoc: TJsonBaseObject; const APath: string);
procedure JsonAddO(ADoc: TJsonBaseObject; const APath: string);
procedure JsonAddJson(ADoc: TJsonBaseObject; const APath, AJsonValue: string);
procedure JsonAddNode(ADoc: TJsonBaseObject; const APath: string; ASrc: TJsonBaseObject);

procedure JsonInsS(ADoc: TJsonBaseObject; const APath: string; AIndex: Integer; const AValue: string);
procedure JsonInsI(ADoc: TJsonBaseObject; const APath: string; AIndex, AValue: Integer);
procedure JsonInsL(ADoc: TJsonBaseObject; const APath: string; AIndex: Integer; AValue: Int64);
procedure JsonInsF(ADoc: TJsonBaseObject; const APath: string; AIndex: Integer; AValue: Double);
procedure JsonInsB(ADoc: TJsonBaseObject; const APath: string; AIndex: Integer; AValue: Boolean);
procedure JsonInsD(ADoc: TJsonBaseObject; const APath: string; AIndex: Integer; AValue: TDateTime);
procedure JsonInsA(ADoc: TJsonBaseObject; const APath: string; AIndex: Integer);
procedure JsonInsO(ADoc: TJsonBaseObject; const APath: string; AIndex: Integer);
procedure JsonInsJson(ADoc: TJsonBaseObject; const APath: string; AIndex: Integer; const AJsonValue: string);
procedure JsonInsNode(ADoc: TJsonBaseObject; const APath: string; AIndex: Integer; ASrc: TJsonBaseObject);

procedure JsonAssign(ADoc: TJsonBaseObject; const APath: string; ASrc: TJsonBaseObject);
procedure JsonClear(ADoc: TJsonBaseObject; const APath: string);
procedure JsonSetLen(ADoc: TJsonBaseObject; const APath: string; ACount: Integer);
function JsonIndexOf(ADoc: TJsonBaseObject; const APath: string; out AIndex: Integer): Boolean;
function JsonNameOf(ADoc: TJsonBaseObject; const APath: string; AIndex: Integer;
  out AName: string): Boolean;
procedure JsonDeleteOf(ADoc: TJsonBaseObject; const APath: string; AIndex: Integer);
function JsonExtract(ADoc: TJsonBaseObject; const APath: string; out AJson: string): Boolean;
function JsonExtractTree(ADoc: TJsonBaseObject; const APath: string;
  out ATree: TJsonBaseObject): Boolean;

function JsonIndexPath(AIndex: Integer): string;
function JsonDump(ADoc: TJsonBaseObject; ACompact: Boolean): string;
procedure JsonCollectNodes(ADoc: TJsonBaseObject; const APath: string;
  AFullPath: Boolean; ARows: TList<TJsonNodeRow>);
procedure JsonCollectItems(ADoc: TJsonBaseObject; const APath: string;
  ARows: TList<TJsonNodeRow>);

implementation

type
  TSink = record
    IsRoot: Boolean;
    ParentObj: TJsonObject;
    ParentArr: TJsonArray;
    Name: string;
    Index: Integer;
    UseIndex: Boolean;
  end;

procedure PathError(const APath: string);
begin
  raise EJsonUdr.CreateFmt('Invalid JSON path "%s"', [APath]);
end;

procedure PathIndexError(const APath: string; ACount: Integer);
begin
  raise EJsonUdr.CreateFmt('JSON path index out of bounds (%d) "%s"', [ACount, APath]);
end;

procedure PathNullError(const APath: string);
begin
  raise EJsonUdr.CreateFmt('JSON path contains null "%s"', [APath]);
end;

procedure NeedWritePath(const APath: string);
begin
  if APath = '' then
    raise EJsonUdr.Create('Cannot write to JSON root; use a path');
end;

function JsonIndexPath(AIndex: Integer): string;
begin
  if AIndex < 0 then
    raise EJsonUdr.Create('JSON array index must be >= 0');
  Result := '[' + IntToStr(AIndex) + ']';
end;

function JsonParseDoc(const AText: string): TJsonBaseObject;
begin
  Result := TJsonBaseObject.Parse(AText);
  if Result = nil then
    raise EJsonUdr.Create('Invalid JSON');
end;

function JsonParseLiteral(const AText: string): TJsonObject;
begin
  Result := TJsonBaseObject.Parse('{"$":' + AText + '}') as TJsonObject;
  if (Result = nil) or (Result.IndexOf('$') < 0) then
  begin
    Result.Free;
    raise EJsonUdr.Create('Invalid JSON value');
  end;
end;

function ParseIndex(var P: PChar; const APath: string): Integer;
var
  V: Int64;
begin
  { Index above High(Integer) is clamped: read -> "no such element",
    write -> out of bounds. No silent wrap to a negative index. }
  if P^ <> '[' then
    PathError(APath);
  Inc(P);
  if not CharInSet(P^, ['0'..'9']) then
    PathError(APath);
  V := 0;
  while CharInSet(P^, ['0'..'9']) do
  begin
    if V <= High(Integer) then
      V := V * 10 + (Ord(P^) - Ord('0'));
    Inc(P);
  end;
  if P^ <> ']' then
    PathError(APath);
  Inc(P);
  if V > High(Integer) then
    Result := High(Integer)
  else
    Result := Integer(V);
end;

function ParseName(var P: PChar; const APath: string): string;
var
  S: PChar;
begin
  S := P;
  while not CharInSet(P^, [#0, '.', '[']) do
    Inc(P);
  if P = S then
    PathError(APath);
  SetString(Result, S, P - S);
end;

procedure WalkRead(ADoc: TJsonBaseObject; const APath: string;
  out AItem: PJsonDataValue; out ARoot: Boolean; out AFound: Boolean);

  procedure Fail;
  begin
    AItem := nil;
    AFound := False;
  end;

var
  P: PChar;
  CurObj: TJsonObject;
  CurArr: TJsonArray;
  CurItem: PJsonDataValue;
  Name: string;
  Idx: Integer;
begin
  AItem := nil;
  ARoot := APath = '';
  AFound := False;
  if ARoot then
  begin
    AFound := True;
    Exit;
  end;

  CurObj := nil;
  CurArr := nil;
  if ADoc is TJsonArray then
    CurArr := TJsonArray(ADoc)
  else
    CurObj := TJsonObject(ADoc);

  P := PChar(APath);
  if CurArr <> nil then
  begin
    if P^ <> '[' then
    begin
      Fail;
      Exit;
    end;
  end
  else if P^ = '[' then
    PathError(APath);

  while True do
  begin
    if CurArr <> nil then
    begin
      Idx := ParseIndex(P, APath);
      if Idx >= CurArr.Count then
      begin
        Fail;
        Exit;
      end;
      CurItem := CurArr.Items[Idx];
      CurArr := nil;
    end
    else
    begin
      Name := ParseName(P, APath);
      if CurObj = nil then
      begin
        Fail;
        Exit;
      end;
      Idx := CurObj.IndexOf(Name);
      if Idx < 0 then
      begin
        Fail;
        Exit;
      end;
      CurItem := CurObj.Items[Idx];
      CurObj := nil;
    end;

    case P^ of
      #0:
        begin
          AItem := CurItem;
          AFound := True;
          Exit;
        end;
      '.':
        begin
          Inc(P);
          if CurItem.IsNull or (CurItem.Typ <> jdtObject) then
          begin
            Fail;
            Exit;
          end;
          CurObj := CurItem.ObjectValue;
        end;
      '[':
        begin
          if CurItem.IsNull or (CurItem.Typ <> jdtArray) then
          begin
            Fail;
            Exit;
          end;
          CurArr := CurItem.ArrayValue;
        end;
    else
      PathError(APath);
    end;
  end;
end;

procedure PathTypeError(const APath, AWhat: string);
begin
  raise EJsonUdr.CreateFmt('JSON path segment is not an %s "%s"', [AWhat, APath]);
end;

{ One pass over the write path.
  ADryRun = True: nothing is created; missing containers are only "virtual".
  Every error a real pass could raise (bad syntax, JSON null / wrong type on
  the way, index out of bounds - including an index into a not yet created
  array) is raised here, so the real pass never fails half-way and never
  leaves empty intermediate objects/arrays behind. }
procedure WalkWritePass(ADoc: TJsonBaseObject; const APath: string;
  ADryRun: Boolean; out Sink: TSink);
var
  P: PChar;
  CurObj: TJsonObject;
  CurArr: TJsonArray;
  InArr: Boolean;    { current container is an array (else an object) }
  Virt: Boolean;     { current container does not exist yet (dry run only) }
  Item: PJsonDataValue;
  Name: string;
  Idx: Integer;

  { Step into an existing item: next container must be of the expected kind }
  procedure EnterItem(AItem: PJsonDataValue; AWantArray: Boolean);
  begin
    if AItem.IsNull then
      PathNullError(APath);
    if AWantArray then
    begin
      if AItem.Typ <> jdtArray then
        PathTypeError(APath, 'array');
      CurArr := AItem.ArrayValue;
      CurObj := nil;
    end
    else
    begin
      if AItem.Typ <> jdtObject then
        PathTypeError(APath, 'object');
      CurObj := AItem.ObjectValue;
      CurArr := nil;
    end;
    InArr := AWantArray;
  end;

begin
  Sink := Default(TSink);
  Sink.IsRoot := APath = '';
  if Sink.IsRoot then
    Exit;

  CurObj := nil;
  CurArr := nil;
  Virt := False;
  InArr := ADoc is TJsonArray;
  if InArr then
    CurArr := TJsonArray(ADoc)
  else
    CurObj := TJsonObject(ADoc);

  P := PChar(APath);
  if InArr <> (P^ = '[') then
    PathError(APath);

  while True do
  begin
    if InArr then
    begin
      Idx := ParseIndex(P, APath);
      if Virt then
        PathIndexError(APath, 0);
      if Idx >= CurArr.Count then
        PathIndexError(APath, CurArr.Count);
      if P^ = #0 then
      begin
        Sink.ParentArr := CurArr;
        Sink.Index := Idx;
        Sink.UseIndex := True;
        Exit;
      end;
      Item := CurArr.Items[Idx];
      case P^ of
        '.':
          begin
            Inc(P);
            EnterItem(Item, False);
          end;
        '[':
          EnterItem(Item, True);
      else
        PathError(APath);
      end;
    end
    else
    begin
      Name := ParseName(P, APath);
      if P^ = #0 then
      begin
        Sink.ParentObj := CurObj;
        Sink.Name := Name;
        Exit;
      end;
      if not CharInSet(P^, ['.', '[']) then
        PathError(APath);
      if Virt then
        Idx := -1
      else
        Idx := CurObj.IndexOf(Name);
      if Idx >= 0 then
        EnterItem(CurObj.Items[Idx], P^ = '[')
      else if ADryRun then
      begin
        Virt := True;
        InArr := P^ = '[';
        CurObj := nil;
        CurArr := nil;
      end
      else if P^ = '[' then
      begin
        CurArr := CurObj.A[Name];
        CurObj := nil;
        InArr := True;
      end
      else
        CurObj := CurObj.O[Name];
      if P^ = '.' then
        Inc(P);
    end;
  end;
end;

procedure WalkWrite(ADoc: TJsonBaseObject; const APath: string; out Sink: TSink);
begin
  WalkWritePass(ADoc, APath, True, Sink);
  WalkWritePass(ADoc, APath, False, Sink);
end;

{ Count of the array at APath for write-side validation; 0 if it does not exist yet
  (ADD/INS will create it). Raises if the node exists and is not an array. }
function ArrayCountForWrite(ADoc: TJsonBaseObject; const APath: string): Integer;
var
  Item: PJsonDataValue;
  Root, Found: Boolean;
begin
  Result := 0;
  if APath = '' then
  begin
    if ADoc is TJsonArray then
      Result := TJsonArray(ADoc).Count;
    Exit;
  end;
  WalkRead(ADoc, APath, Item, Root, Found);
  if Found and (Item <> nil) and (not Item.IsNull) then
  begin
    if Item.Typ <> jdtArray then
      raise EJsonUdr.Create('ADD/INSERT path is not an array');
    Result := Item.ArrayValue.Count;
  end;
end;

procedure CheckInsIndex(ADoc: TJsonBaseObject; const APath: string; AIndex: Integer);
var
  N: Integer;
begin
  N := ArrayCountForWrite(ADoc, APath);
  if (AIndex < 0) or (AIndex > N) then
    raise EJsonUdr.CreateFmt('INSERT index %d out of bounds (0..%d) "%s"',
      [AIndex, N, APath]);
end;

function ItemIsNull(AItem: PJsonDataValue): Boolean;
begin
  Result := (AItem = nil) or AItem.IsNull;
end;

function JsonGetS(ADoc: TJsonBaseObject; const APath: string; out AValue: string): Boolean;
var
  Item: PJsonDataValue;
  Root, Found: Boolean;
begin
  AValue := '';
  WalkRead(ADoc, APath, Item, Root, Found);
  if not Found then
    Exit(False);
  if Root then
    Exit(False);
  if ItemIsNull(Item) then
    Exit(False);
  if Item.Typ in [jdtArray, jdtObject] then
    raise EJsonUdr.Create('Cannot convert JSON array/object to string');
  AValue := Item.Value;
  Result := True;
end;

function JsonGetL(ADoc: TJsonBaseObject; const APath: string; out AValue: Int64): Boolean;
var
  Item: PJsonDataValue;
  Root, Found: Boolean;
begin
  AValue := 0;
  WalkRead(ADoc, APath, Item, Root, Found);
  if (not Found) or Root then
    Exit(False);
  if ItemIsNull(Item) then
    Exit(False);
  if Item.Typ in [jdtArray, jdtObject] then
    raise EJsonUdr.Create('Cannot convert JSON array/object to integer');
  AValue := Item.LongValue;
  Result := True;
end;

function JsonGetI(ADoc: TJsonBaseObject; const APath: string; out AValue: Integer): Boolean;
var
  L: Int64;
begin
  AValue := 0;
  if not JsonGetL(ADoc, APath, L) then
    Exit(False);
  if (L < Low(Integer)) or (L > High(Integer)) then
    raise EJsonUdr.Create('JSON integer overflow for INTEGER');
  AValue := Integer(L);
  Result := True;
end;

function JsonGetF(ADoc: TJsonBaseObject; const APath: string; out AValue: Double): Boolean;
var
  Item: PJsonDataValue;
  Root, Found: Boolean;
begin
  AValue := 0;
  WalkRead(ADoc, APath, Item, Root, Found);
  if (not Found) or Root then
    Exit(False);
  if ItemIsNull(Item) then
    Exit(False);
  if Item.Typ in [jdtArray, jdtObject] then
    raise EJsonUdr.Create('Cannot convert JSON array/object to float');
  AValue := Item.FloatValue;
  Result := True;
end;

function JsonGetB(ADoc: TJsonBaseObject; const APath: string; out AValue: Boolean): Boolean;
var
  Item: PJsonDataValue;
  Root, Found: Boolean;
begin
  AValue := False;
  WalkRead(ADoc, APath, Item, Root, Found);
  if (not Found) or Root then
    Exit(False);
  if ItemIsNull(Item) then
    Exit(False);
  if Item.Typ in [jdtArray, jdtObject] then
    raise EJsonUdr.Create('Cannot convert JSON array/object to boolean');
  AValue := Item.BoolValue;
  Result := True;
end;

function JsonGetD(ADoc: TJsonBaseObject; const APath: string; out AValue: TDateTime): Boolean;
var
  Item: PJsonDataValue;
  Root, Found: Boolean;
begin
  AValue := 0;
  WalkRead(ADoc, APath, Item, Root, Found);
  if (not Found) or Root then
    Exit(False);
  if ItemIsNull(Item) then
    Exit(False);
  if Item.Typ in [jdtArray, jdtObject] then
    raise EJsonUdr.Create('Cannot convert JSON array/object to timestamp');
  AValue := Item.DateTimeValue;
  Result := True;
end;

function JsonDump(ADoc: TJsonBaseObject; ACompact: Boolean): string;
begin
  Result := ADoc.ToJSON(ACompact);
end;

function ItemToJson(AItem: PJsonDataValue; ACompact: Boolean): string;
var
  Wrap: TJsonArray;
begin
  if AItem.IsNull then
    Exit('null');
  case AItem.Typ of
    jdtArray:
      Result := AItem.ArrayValue.ToJSON(ACompact);
    jdtObject:
      Result := AItem.ObjectValue.ToJSON(ACompact);
  else
    Wrap := TJsonArray.Create;
    try
      case AItem.Typ of
        jdtString:
          Wrap.Add(AItem.Value);
        jdtInt:
          Wrap.Add(AItem.IntValue);
        jdtLong:
          Wrap.Add(AItem.LongValue);
        jdtULong:
          Wrap.Add(AItem.ULongValue);
        jdtFloat:
          Wrap.Add(AItem.FloatValue);
        jdtDateTime:
          Wrap.Add(AItem.DateTimeValue);
        jdtUtcDateTime:
          Wrap.AddUtcDateTime(AItem.UtcDateTimeValue);
        jdtBool:
          Wrap.Add(AItem.BoolValue);
      else
        Wrap.Add(AItem.Value);
      end;
      Result := Wrap.ToJSON(True);
      if (Length(Result) >= 2) and (Result[1] = '[') then
        Result := Copy(Result, 2, Length(Result) - 2);
    finally
      Wrap.Free;
    end;
  end;
end;

function ItemToScalarText(AItem: PJsonDataValue): string;
begin
  if (AItem = nil) or AItem.IsNull then
    Exit('null');
  if AItem.Typ in [jdtString, jdtDateTime, jdtUtcDateTime] then
    Exit(AItem.Value);  { as GET_S: ISO text without JSON quotes }
  Result := ItemToJson(AItem, True);
end;

function PathLastSegment(const APath: string): string;
var
  I: Integer;
begin
  if APath = '' then
    Exit('');
  if APath[Length(APath)] = ']' then
  begin
    I := Length(APath);
    while (I > 1) and (APath[I] <> '[') do
      Dec(I);
    Result := Copy(APath, I, MaxInt);
  end
  else
  begin
    I := Length(APath);
    while (I > 0) and (APath[I] <> '.') do
      Dec(I);
    Result := Copy(APath, I + 1, MaxInt);
  end;
end;

function PathJoinName(const AParent, AName: string): string;
begin
  if AParent = '' then
    Result := AName
  else if (AName <> '') and (AName[1] = '[') then
    Result := AParent + AName
  else
    Result := AParent + '.' + AName;
end;

function PathJoinIndex(const AParent: string; AIndex: Integer): string;
begin
  Result := AParent + '[' + IntToStr(AIndex) + ']';
end;

function PathParent(const APath: string): string;
var
  Seg: string;
begin
  Seg := PathLastSegment(APath);
  if (Seg = '') or (Seg = APath) then
    Exit('');
  Result := Copy(APath, 1, Length(APath) - Length(Seg));
  if (Result <> '') and (Result[Length(Result)] = '.') then
    SetLength(Result, Length(Result) - 1);
end;

function StartSiblingIndex(ADoc: TJsonBaseObject; const APath: string): Integer;
var
  Seg, ParentPath: string;
  Item: PJsonDataValue;
  Root, Found: Boolean;
begin
  Seg := PathLastSegment(APath);
  if (Length(Seg) >= 3) and (Seg[1] = '[') and (Seg[Length(Seg)] = ']') then
    Exit(StrToIntDef(Copy(Seg, 2, Length(Seg) - 2), 0));
  ParentPath := PathParent(APath);
  WalkRead(ADoc, ParentPath, Item, Root, Found);
  if not Found then
    Exit(0);
  if Root then
  begin
    if ADoc is TJsonObject then
      Result := TJsonObject(ADoc).IndexOf(Seg)
    else
      Result := 0;
  end
  else if (Item <> nil) and (not Item.IsNull) and (Item.Typ = jdtObject) and
    (Item.ObjectValue <> nil) then
    Result := Item.ObjectValue.IndexOf(Seg)
  else
    Result := 0;
  if Result < 0 then
    Result := 0;
end;

procedure JsonCollectNodes(ADoc: TJsonBaseObject; const APath: string;
  AFullPath: Boolean; ARows: TList<TJsonNodeRow>);
var
  AbsSeq: Integer;
  StartItem: PJsonDataValue;
  Root, Found: Boolean;
  StartLoc: Integer;

  procedure Emit(ALoc: Integer; const AName, ANodePath, ATyp, AVal: string);
  var
    Row: TJsonNodeRow;
  begin
    Row.AbsIdx := AbsSeq;
    Inc(AbsSeq);
    Row.LocIdx := ALoc;
    Row.Name := AName;
    Row.Path := ANodePath;
    Row.Typ := ATyp;
    Row.Val := AVal;
    ARows.Add(Row);
  end;

  procedure WalkPtr(AItem: PJsonDataValue; const AName, ANodePath: string; ASib: Integer); forward;

  procedure WalkBase(ANode: TJsonBaseObject; const AName, ANodePath: string);
  var
    Obj: TJsonObject;
    Arr: TJsonArray;
    I: Integer;
    ChildName: string;
  begin
    if ANode is TJsonArray then
    begin
      Arr := TJsonArray(ANode);
      Emit(Arr.Count, AName, ANodePath, 'Array', '[]');
      for I := 0 to Arr.Count - 1 do
      begin
        ChildName := '[' + IntToStr(I) + ']';
        WalkPtr(Arr.Items[I], ChildName, PathJoinIndex(ANodePath, I), I);
      end;
    end
    else
    begin
      Obj := TJsonObject(ANode);
      Emit(Obj.Count, AName, ANodePath, 'Object', '{}');
      for I := 0 to Obj.Count - 1 do
      begin
        ChildName := Obj.Names[I];
        WalkPtr(Obj.Items[I], ChildName, PathJoinName(ANodePath, ChildName), I);
      end;
    end;
  end;

  procedure WalkPtr(AItem: PJsonDataValue; const AName, ANodePath: string; ASib: Integer);
  begin
    if (AItem = nil) or AItem.IsNull then
    begin
      Emit(ASib, AName, ANodePath, 'null', 'null');
      Exit;
    end;
    case AItem.Typ of
      jdtArray:
        WalkBase(AItem.ArrayValue, AName, ANodePath);
      jdtObject:
        WalkBase(AItem.ObjectValue, AName, ANodePath);
    else
      Emit(ASib, AName, ANodePath, TJsonBaseObject.DataTypeNames[AItem.Typ],
        ItemToScalarText(AItem));
    end;
  end;

begin
  ARows.Clear;
  AbsSeq := 0;
  WalkRead(ADoc, APath, StartItem, Root, Found);
  if not Found then
    Exit;
  if Root then
    WalkBase(ADoc, '', '')
  else
  begin
    StartLoc := StartSiblingIndex(ADoc, APath);
    if AFullPath then
      WalkPtr(StartItem, PathLastSegment(APath), APath, StartLoc)
    else
      WalkPtr(StartItem, PathLastSegment(APath), '', StartLoc);
  end;
end;

procedure JsonCollectItems(ADoc: TJsonBaseObject; const APath: string;
  ARows: TList<TJsonNodeRow>);
var
  StartItem: PJsonDataValue;
  Root, Found: Boolean;
  Arr: TJsonArray;
  I: Integer;

  function ItemTyp(AItem: PJsonDataValue): string;
  begin
    if (AItem = nil) or AItem.IsNull then
      Exit('null');
    Result := TJsonBaseObject.DataTypeNames[AItem.Typ];
  end;

  function ItemVal(AItem: PJsonDataValue): string;
  begin
    if (AItem = nil) or AItem.IsNull then
      Exit('null');
    case AItem.Typ of
      jdtArray, jdtObject:
        Result := ItemToJson(AItem, True);
    else
      Result := ItemToScalarText(AItem);
    end;
  end;

  procedure Emit(ALoc: Integer; const AName, ATyp, AVal: string);
  var
    Row: TJsonNodeRow;
  begin
    Row.AbsIdx := 0;
    Row.Path := '';
    Row.LocIdx := ALoc;
    Row.Name := AName;
    Row.Typ := ATyp;
    Row.Val := AVal;
    ARows.Add(Row);
  end;

  procedure EmitElem(ALoc: Integer; AItem: PJsonDataValue);
  var
    Obj: TJsonObject;
    K: Integer;
    Child: PJsonDataValue;
  begin
    if (AItem = nil) or AItem.IsNull then
    begin
      Emit(ALoc, '[' + IntToStr(ALoc) + ']', 'null', 'null');
      Exit;
    end;
    if AItem.Typ = jdtObject then
    begin
      Obj := AItem.ObjectValue;
      if Obj = nil then
      begin
        Emit(ALoc, '[' + IntToStr(ALoc) + ']', 'null', 'null');
        Exit;
      end;
      for K := 0 to Obj.Count - 1 do
      begin
        Child := Obj.Items[K];
        Emit(ALoc, Obj.Names[K], ItemTyp(Child), ItemVal(Child));
      end;
      Exit;
    end;
    Emit(ALoc, '[' + IntToStr(ALoc) + ']', ItemTyp(AItem), ItemVal(AItem));
  end;

begin
  ARows.Clear;
  WalkRead(ADoc, APath, StartItem, Root, Found);
  if not Found then
    Exit;
  if Root then
  begin
    if not (ADoc is TJsonArray) then
      raise EJsonUdr.Create('ITEMS path is not an array');
    Arr := TJsonArray(ADoc);
  end
  else if (StartItem = nil) or StartItem.IsNull or (StartItem.Typ <> jdtArray) or
    (StartItem.ArrayValue = nil) then
    raise EJsonUdr.Create('ITEMS path is not an array')
  else
    Arr := StartItem.ArrayValue;
  for I := 0 to Arr.Count - 1 do
    EmitElem(I, Arr.Items[I]);
end;

function JsonGetNode(ADoc: TJsonBaseObject; const APath: string; ACompact: Boolean;
  out AJson: string): Boolean;
var
  Item: PJsonDataValue;
  Root, Found: Boolean;
begin
  AJson := '';
  WalkRead(ADoc, APath, Item, Root, Found);
  if not Found then
    Exit(False);
  if Root then
  begin
    AJson := JsonDump(ADoc, ACompact);
    Result := True;
    Exit;
  end;
  AJson := ItemToJson(Item, ACompact);
  Result := True;
end;

function JsonGetTypeName(ADoc: TJsonBaseObject; const APath: string; out AName: string): Boolean;
var
  Item: PJsonDataValue;
  Root, Found: Boolean;
begin
  AName := '';
  WalkRead(ADoc, APath, Item, Root, Found);
  if not Found then
    Exit(False);
  if Root then
  begin
    if ADoc is TJsonArray then
      AName := 'Array'
    else
      AName := 'Object';
    Result := True;
    Exit;
  end;
  if Item.IsNull then
    AName := 'null'
  else
    AName := TJsonBaseObject.DataTypeNames[Item.Typ];
  Result := True;
end;

function JsonExists(ADoc: TJsonBaseObject; const APath: string): Boolean;
var
  Item: PJsonDataValue;
  Root, Found: Boolean;
begin
  WalkRead(ADoc, APath, Item, Root, Found);
  Result := Found;
end;

function JsonIsNull(ADoc: TJsonBaseObject; const APath: string): Boolean;
var
  Item: PJsonDataValue;
  Root, Found: Boolean;
begin
  WalkRead(ADoc, APath, Item, Root, Found);
  if (not Found) or Root then
    Exit(False);
  Result := Item.IsNull;
end;

function JsonCount(ADoc: TJsonBaseObject; const APath: string; out ACount: Integer): Boolean;
var
  Item: PJsonDataValue;
  Root, Found: Boolean;
begin
  ACount := 0;
  WalkRead(ADoc, APath, Item, Root, Found);
  if not Found then
    Exit(False);
  if Root then
  begin
    if ADoc is TJsonArray then
      ACount := TJsonArray(ADoc).Count
    else
      ACount := TJsonObject(ADoc).Count;
    Result := True;
    Exit;
  end;
  if Item.IsNull then
    Exit(False);
  case Item.Typ of
    jdtArray:
      ACount := Item.ArrayValue.Count;
    jdtObject:
      ACount := Item.ObjectValue.Count;
  else
    Exit(False);
  end;
  Result := True;
end;

procedure AssignItemToObject(AObj: TJsonObject; const AName: string; ASrc: PJsonDataValue);
begin
  if ASrc.IsNull then
  begin
    AObj.O[AName] := nil;
    Exit;
  end;
  case ASrc.Typ of
    jdtString:
      AObj.S[AName] := ASrc.Value;
    jdtInt:
      AObj.I[AName] := ASrc.IntValue;
    jdtLong:
      AObj.L[AName] := ASrc.LongValue;
    jdtULong:
      AObj.U[AName] := ASrc.ULongValue;
    jdtFloat:
      AObj.F[AName] := ASrc.FloatValue;
    jdtDateTime:
      AObj.D[AName] := ASrc.DateTimeValue;
    jdtUtcDateTime:
      AObj.DUtc[AName] := ASrc.UtcDateTimeValue;
    jdtBool:
      AObj.B[AName] := ASrc.BoolValue;
    jdtArray:
      AObj.A[AName] := TJsonArray(ASrc.ArrayValue.Clone);
    jdtObject:
      AObj.O[AName] := TJsonObject(ASrc.ObjectValue.Clone);
  else
    AObj.S[AName] := ASrc.Value;
  end;
end;

{ Append a copy of ASrc to AArr (all JDO value types, null included). }
procedure AddItemToArray(AArr: TJsonArray; ASrc: PJsonDataValue);
begin
  if ASrc.IsNull then
  begin
    AArr.AddObject(nil);
    Exit;
  end;
  case ASrc.Typ of
    jdtString:
      AArr.Add(ASrc.Value);
    jdtInt:
      AArr.Add(ASrc.IntValue);
    jdtLong:
      AArr.Add(ASrc.LongValue);
    jdtULong:
      AArr.Add(ASrc.ULongValue);
    jdtFloat:
      AArr.Add(ASrc.FloatValue);
    jdtDateTime:
      AArr.Add(ASrc.DateTimeValue);
    jdtUtcDateTime:
      AArr.AddUtcDateTime(ASrc.UtcDateTimeValue);
    jdtBool:
      AArr.Add(ASrc.BoolValue);
    jdtArray:
      AArr.Add(TJsonArray(ASrc.ArrayValue.Clone));
    jdtObject:
      AArr.Add(TJsonObject(ASrc.ObjectValue.Clone));
  else
    AArr.Add(ASrc.Value);
  end;
end;

{ Insert a copy of ASrc at AIndex (caller has validated AIndex). }
procedure InsertItemToArray(AArr: TJsonArray; AIndex: Integer; ASrc: PJsonDataValue);
begin
  if ASrc.IsNull then
  begin
    AArr.InsertObject(AIndex, nil);
    Exit;
  end;
  case ASrc.Typ of
    jdtString:
      AArr.Insert(AIndex, ASrc.Value);
    jdtInt:
      AArr.Insert(AIndex, ASrc.IntValue);
    jdtLong:
      AArr.Insert(AIndex, ASrc.LongValue);
    jdtULong:
      AArr.Insert(AIndex, ASrc.ULongValue);
    jdtFloat:
      AArr.Insert(AIndex, ASrc.FloatValue);
    jdtDateTime:
      AArr.Insert(AIndex, ASrc.DateTimeValue);
    jdtUtcDateTime:
      AArr.InsertUtcDateTime(AIndex, ASrc.UtcDateTimeValue);
    jdtBool:
      AArr.Insert(AIndex, ASrc.BoolValue);
    jdtArray:
      AArr.Insert(AIndex, TJsonArray(ASrc.ArrayValue.Clone));
    jdtObject:
      AArr.Insert(AIndex, TJsonObject(ASrc.ObjectValue.Clone));
  else
    AArr.Insert(AIndex, ASrc.Value);
  end;
end;

procedure AssignItemToArray(AArr: TJsonArray; AIndex: Integer; ASrc: PJsonDataValue);
begin
  if ASrc.IsNull then
  begin
    AArr.O[AIndex] := nil;
    Exit;
  end;
  case ASrc.Typ of
    jdtString:
      AArr.S[AIndex] := ASrc.Value;
    jdtInt:
      AArr.I[AIndex] := ASrc.IntValue;
    jdtLong:
      AArr.L[AIndex] := ASrc.LongValue;
    jdtULong:
      AArr.U[AIndex] := ASrc.ULongValue;
    jdtFloat:
      AArr.F[AIndex] := ASrc.FloatValue;
    jdtDateTime:
      AArr.D[AIndex] := ASrc.DateTimeValue;
    jdtUtcDateTime:
      AArr.DUtc[AIndex] := ASrc.UtcDateTimeValue;
    jdtBool:
      AArr.B[AIndex] := ASrc.BoolValue;
    jdtArray:
      AArr.A[AIndex] := TJsonArray(ASrc.ArrayValue.Clone);
    jdtObject:
      AArr.O[AIndex] := TJsonObject(ASrc.ObjectValue.Clone);
  else
    AArr.S[AIndex] := ASrc.Value;
  end;
end;

procedure ApplySinkS(const Sink: TSink; const AValue: string);
begin
  if Sink.UseIndex then
    Sink.ParentArr.S[Sink.Index] := AValue
  else
    Sink.ParentObj.S[Sink.Name] := AValue;
end;

procedure JsonSetS(ADoc: TJsonBaseObject; const APath, AValue: string);
var
  Sink: TSink;
begin
  NeedWritePath(APath);
  WalkWrite(ADoc, APath, Sink);
  ApplySinkS(Sink, AValue);
end;

procedure JsonSetI(ADoc: TJsonBaseObject; const APath: string; AValue: Integer);
var
  Sink: TSink;
begin
  NeedWritePath(APath);
  WalkWrite(ADoc, APath, Sink);
  if Sink.UseIndex then
    Sink.ParentArr.I[Sink.Index] := AValue
  else
    Sink.ParentObj.I[Sink.Name] := AValue;
end;

procedure JsonSetL(ADoc: TJsonBaseObject; const APath: string; AValue: Int64);
var
  Sink: TSink;
begin
  NeedWritePath(APath);
  WalkWrite(ADoc, APath, Sink);
  if Sink.UseIndex then
    Sink.ParentArr.L[Sink.Index] := AValue
  else
    Sink.ParentObj.L[Sink.Name] := AValue;
end;

procedure JsonSetF(ADoc: TJsonBaseObject; const APath: string; AValue: Double);
var
  Sink: TSink;
begin
  NeedWritePath(APath);
  WalkWrite(ADoc, APath, Sink);
  if Sink.UseIndex then
    Sink.ParentArr.F[Sink.Index] := AValue
  else
    Sink.ParentObj.F[Sink.Name] := AValue;
end;

procedure JsonSetB(ADoc: TJsonBaseObject; const APath: string; AValue: Boolean);
var
  Sink: TSink;
begin
  NeedWritePath(APath);
  WalkWrite(ADoc, APath, Sink);
  if Sink.UseIndex then
    Sink.ParentArr.B[Sink.Index] := AValue
  else
    Sink.ParentObj.B[Sink.Name] := AValue;
end;

procedure JsonSetD(ADoc: TJsonBaseObject; const APath: string; AValue: TDateTime);
var
  Sink: TSink;
begin
  NeedWritePath(APath);
  WalkWrite(ADoc, APath, Sink);
  if Sink.UseIndex then
    Sink.ParentArr.D[Sink.Index] := AValue
  else
    Sink.ParentObj.D[Sink.Name] := AValue;
end;

procedure JsonSetNull(ADoc: TJsonBaseObject; const APath: string);
var
  Sink: TSink;
begin
  NeedWritePath(APath);
  WalkWrite(ADoc, APath, Sink);
  if Sink.UseIndex then
    Sink.ParentArr.O[Sink.Index] := nil
  else
    Sink.ParentObj.O[Sink.Name] := nil;
end;

procedure JsonSetJson(ADoc: TJsonBaseObject; const APath, AJsonValue: string);
var
  Sink: TSink;
  Wrap: TJsonObject;
  Src: PJsonDataValue;
begin
  NeedWritePath(APath);
  Wrap := JsonParseLiteral(AJsonValue);  { invalid literal -> error before any write }
  try
    WalkWrite(ADoc, APath, Sink);
    Src := Wrap.Items[Wrap.IndexOf('$')];
    if Sink.UseIndex then
      AssignItemToArray(Sink.ParentArr, Sink.Index, Src)
    else
      AssignItemToObject(Sink.ParentObj, Sink.Name, Src);
  finally
    Wrap.Free;
  end;
end;

procedure TakeCloned(var AClone: TJsonBaseObject);
begin
  AClone := nil;
end;

procedure JsonSetNode(ADoc: TJsonBaseObject; const APath: string; ASrc: TJsonBaseObject);
var
  Sink: TSink;
  C: TJsonBaseObject;
begin
  NeedWritePath(APath);
  C := ASrc.Clone;  { clone first: ASrc may be ADoc itself }
  try
    WalkWrite(ADoc, APath, Sink);
    if C is TJsonArray then
    begin
      if Sink.UseIndex then
        Sink.ParentArr.A[Sink.Index] := TJsonArray(C)
      else
        Sink.ParentObj.A[Sink.Name] := TJsonArray(C);
    end
    else
    begin
      if Sink.UseIndex then
        Sink.ParentArr.O[Sink.Index] := TJsonObject(C)
      else
        Sink.ParentObj.O[Sink.Name] := TJsonObject(C);
    end;
    TakeCloned(C);
  finally
    C.Free;
  end;
end;

procedure JsonRemove(ADoc: TJsonBaseObject; const APath: string);
var
  Item: PJsonDataValue;
  Root, Found: Boolean;
  Sink: TSink;
begin
  if APath = '' then
    raise EJsonUdr.Create('Cannot REMOVE JSON root');
  WalkRead(ADoc, APath, Item, Root, Found);
  if not Found then
    Exit;
  WalkWrite(ADoc, APath, Sink);
  if Sink.UseIndex then
    Sink.ParentArr.Delete(Sink.Index)
  else
    Sink.ParentObj.Remove(Sink.Name);
end;

{ Object/array stored at the sink; created when missing or JSON null
  (JDO A[]/O[] return nil for a null slot). Wrong type -> exception. }
function SinkContainer(const Sink: TSink; AArray: Boolean): TJsonBaseObject;
var
  Item: PJsonDataValue;
  Idx: Integer;
begin
  Item := nil;
  if Sink.UseIndex then
    Item := Sink.ParentArr.Items[Sink.Index]
  else
  begin
    Idx := Sink.ParentObj.IndexOf(Sink.Name);
    if Idx >= 0 then
      Item := Sink.ParentObj.Items[Idx];
  end;
  if (Item <> nil) and not Item.IsNull then
  begin
    if AArray then
    begin
      if Item.Typ <> jdtArray then
        raise EJsonUdr.Create('JSON path is not an array');
      Exit(Item.ArrayValue);
    end;
    if Item.Typ <> jdtObject then
      raise EJsonUdr.Create('JSON path is not an object');
    Exit(Item.ObjectValue);
  end;
  if AArray then
  begin
    Result := TJsonArray.Create;
    if Sink.UseIndex then
      Sink.ParentArr.A[Sink.Index] := TJsonArray(Result)
    else
      Sink.ParentObj.A[Sink.Name] := TJsonArray(Result);
  end
  else
  begin
    Result := TJsonObject.Create;
    if Sink.UseIndex then
      Sink.ParentArr.O[Sink.Index] := TJsonObject(Result)
    else
      Sink.ParentObj.O[Sink.Name] := TJsonObject(Result);
  end;
end;

function RequireArray(ADoc: TJsonBaseObject; const APath: string): TJsonArray;
var
  Sink: TSink;
begin
  if APath = '' then
  begin
    if not (ADoc is TJsonArray) then
      raise EJsonUdr.Create('ADD/INSERT path is empty but root is not an array');
    Result := TJsonArray(ADoc);
    Exit;
  end;
  ArrayCountForWrite(ADoc, APath);  { type check before anything is created }
  WalkWrite(ADoc, APath, Sink);
  Result := SinkContainer(Sink, True) as TJsonArray;
end;

{ RequireArray for INS_*: index 0..Count is checked before the array or its
  parents are created. }
function RequireInsArray(ADoc: TJsonBaseObject; const APath: string;
  AIndex: Integer): TJsonArray;
begin
  CheckInsIndex(ADoc, APath, AIndex);
  Result := RequireArray(ADoc, APath);
end;

procedure JsonAddS(ADoc: TJsonBaseObject; const APath, AValue: string);
begin
  RequireArray(ADoc, APath).Add(AValue);
end;

procedure JsonAddI(ADoc: TJsonBaseObject; const APath: string; AValue: Integer);
begin
  RequireArray(ADoc, APath).Add(AValue);
end;

procedure JsonAddL(ADoc: TJsonBaseObject; const APath: string; AValue: Int64);
begin
  RequireArray(ADoc, APath).Add(AValue);
end;

procedure JsonAddF(ADoc: TJsonBaseObject; const APath: string; AValue: Double);
begin
  RequireArray(ADoc, APath).Add(AValue);
end;

procedure JsonAddB(ADoc: TJsonBaseObject; const APath: string; AValue: Boolean);
begin
  RequireArray(ADoc, APath).Add(AValue);
end;

procedure JsonAddD(ADoc: TJsonBaseObject; const APath: string; AValue: TDateTime);
begin
  RequireArray(ADoc, APath).Add(AValue);
end;

procedure JsonAddA(ADoc: TJsonBaseObject; const APath: string);
begin
  RequireArray(ADoc, APath).AddArray;
end;

procedure JsonAddO(ADoc: TJsonBaseObject; const APath: string);
begin
  RequireArray(ADoc, APath).AddObject;
end;

procedure JsonAddJson(ADoc: TJsonBaseObject; const APath, AJsonValue: string);
var
  Arr: TJsonArray;
  Wrap: TJsonObject;
  Src: PJsonDataValue;
begin
  Wrap := JsonParseLiteral(AJsonValue);  { invalid literal -> error before any write }
  try
    Arr := RequireArray(ADoc, APath);
    Src := Wrap.Items[Wrap.IndexOf('$')];
    AddItemToArray(Arr, Src);
  finally
    Wrap.Free;
  end;
end;

procedure JsonAddNode(ADoc: TJsonBaseObject; const APath: string; ASrc: TJsonBaseObject);
var
  Arr: TJsonArray;
  C: TJsonBaseObject;
begin
  C := ASrc.Clone;  { clone first: ASrc may be ADoc itself }
  try
    Arr := RequireArray(ADoc, APath);
    if C is TJsonArray then
      Arr.Add(TJsonArray(C))
    else
      Arr.Add(TJsonObject(C));
    TakeCloned(C);
  finally
    C.Free;
  end;
end;

procedure JsonInsS(ADoc: TJsonBaseObject; const APath: string; AIndex: Integer; const AValue: string);
begin
  RequireInsArray(ADoc, APath, AIndex).Insert(AIndex, AValue);
end;

procedure JsonInsI(ADoc: TJsonBaseObject; const APath: string; AIndex, AValue: Integer);
begin
  RequireInsArray(ADoc, APath, AIndex).Insert(AIndex, AValue);
end;

procedure JsonInsL(ADoc: TJsonBaseObject; const APath: string; AIndex: Integer; AValue: Int64);
begin
  RequireInsArray(ADoc, APath, AIndex).Insert(AIndex, AValue);
end;

procedure JsonInsF(ADoc: TJsonBaseObject; const APath: string; AIndex: Integer; AValue: Double);
begin
  RequireInsArray(ADoc, APath, AIndex).Insert(AIndex, AValue);
end;

procedure JsonInsB(ADoc: TJsonBaseObject; const APath: string; AIndex: Integer; AValue: Boolean);
begin
  RequireInsArray(ADoc, APath, AIndex).Insert(AIndex, AValue);
end;

procedure JsonInsD(ADoc: TJsonBaseObject; const APath: string; AIndex: Integer; AValue: TDateTime);
begin
  RequireInsArray(ADoc, APath, AIndex).Insert(AIndex, AValue);
end;

procedure JsonInsA(ADoc: TJsonBaseObject; const APath: string; AIndex: Integer);
begin
  RequireInsArray(ADoc, APath, AIndex).InsertArray(AIndex);
end;

procedure JsonInsO(ADoc: TJsonBaseObject; const APath: string; AIndex: Integer);
begin
  RequireInsArray(ADoc, APath, AIndex).InsertObject(AIndex);
end;

procedure JsonInsJson(ADoc: TJsonBaseObject; const APath: string; AIndex: Integer;
  const AJsonValue: string);
var
  Arr: TJsonArray;
  Wrap: TJsonObject;
  Src: PJsonDataValue;
begin
  Wrap := JsonParseLiteral(AJsonValue);  { invalid literal -> error before any write }
  try
    Arr := RequireInsArray(ADoc, APath, AIndex);
    Src := Wrap.Items[Wrap.IndexOf('$')];
    InsertItemToArray(Arr, AIndex, Src);
  finally
    Wrap.Free;
  end;
end;

procedure JsonInsNode(ADoc: TJsonBaseObject; const APath: string; AIndex: Integer;
  ASrc: TJsonBaseObject);
var
  Arr: TJsonArray;
  C: TJsonBaseObject;
begin
  C := ASrc.Clone;  { clone first: ASrc may be ADoc itself }
  try
    Arr := RequireInsArray(ADoc, APath, AIndex);
    if C is TJsonArray then
      Arr.Insert(AIndex, TJsonArray(C))
    else
      Arr.Insert(AIndex, TJsonObject(C));
    TakeCloned(C);
  finally
    C.Free;
  end;
end;

function ObjectAt(ADoc: TJsonBaseObject; const APath: string): TJsonObject;
var
  Item: PJsonDataValue;
  Root, Found: Boolean;
begin
  WalkRead(ADoc, APath, Item, Root, Found);
  if not Found then
    raise EJsonUdr.CreateFmt('JSON path not found "%s"', [APath]);
  if Root then
  begin
    if not (ADoc is TJsonObject) then
      raise EJsonUdr.Create('Path is not a JSON object');
    Exit(TJsonObject(ADoc));
  end;
  if ItemIsNull(Item) or (Item.Typ <> jdtObject) or (Item.ObjectValue = nil) then
    raise EJsonUdr.Create('Path is not a JSON object');
  Result := Item.ObjectValue;
end;

procedure JsonAssign(ADoc: TJsonBaseObject; const APath: string; ASrc: TJsonBaseObject);
var
  Sink: TSink;
begin
  if ASrc = nil then
    raise EJsonUdr.Create('ASSIGN source is null');
  if APath = '' then
  begin
    if (ADoc is TJsonObject) and (ASrc is TJsonObject) then
      TJsonObject(ADoc).Assign(TJsonObject(ASrc))
    else if (ADoc is TJsonArray) and (ASrc is TJsonArray) then
      TJsonArray(ADoc).Assign(TJsonArray(ASrc))
    else
      raise EJsonUdr.Create('ASSIGN root type mismatch');
    Exit;
  end;
  if not ((ASrc is TJsonObject) or (ASrc is TJsonArray)) then
    raise EJsonUdr.Create('ASSIGN source is not an object or array');
  WalkWrite(ADoc, APath, Sink);
  { missing or JSON null target -> created; other type -> exception }
  if ASrc is TJsonObject then
    TJsonObject(SinkContainer(Sink, False)).Assign(TJsonObject(ASrc))
  else
    TJsonArray(SinkContainer(Sink, True)).Assign(TJsonArray(ASrc));
end;

procedure JsonClear(ADoc: TJsonBaseObject; const APath: string);
var
  Item: PJsonDataValue;
  Root, Found: Boolean;
begin
  WalkRead(ADoc, APath, Item, Root, Found);
  if not Found then
    raise EJsonUdr.CreateFmt('JSON path not found "%s"', [APath]);
  if Root then
  begin
    if ADoc is TJsonArray then
      TJsonArray(ADoc).Clear
    else
      TJsonObject(ADoc).Clear;
    Exit;
  end;
  if ItemIsNull(Item) then
    raise EJsonUdr.Create('CLEAR path is JSON null');
  case Item.Typ of
    jdtArray:
      Item.ArrayValue.Clear;
    jdtObject:
      Item.ObjectValue.Clear;
  else
    raise EJsonUdr.Create('CLEAR path is not an object or array');
  end;
end;

procedure JsonSetLen(ADoc: TJsonBaseObject; const APath: string; ACount: Integer);
begin
  if ACount < 0 then
    raise EJsonUdr.Create('SET_LEN count must be >= 0');
  RequireArray(ADoc, APath).Count := ACount;
end;

function JsonIndexOf(ADoc: TJsonBaseObject; const APath: string; out AIndex: Integer): Boolean;
var
  Seg, ParentPath: string;
  Item: PJsonDataValue;
  Root, Found: Boolean;
begin
  AIndex := 0;
  if APath = '' then
    Exit(False);
  Seg := PathLastSegment(APath);
  if (Length(Seg) >= 3) and (Seg[1] = '[') and (Seg[Length(Seg)] = ']') then
  begin
    WalkRead(ADoc, APath, Item, Root, Found);
    if not Found then
      Exit(False);
    AIndex := StrToIntDef(Copy(Seg, 2, Length(Seg) - 2), -1);
    Result := AIndex >= 0;
    Exit;
  end;
  ParentPath := PathParent(APath);
  WalkRead(ADoc, ParentPath, Item, Root, Found);
  if not Found then
    Exit(False);
  if Root then
  begin
    if not (ADoc is TJsonObject) then
      Exit(False);
    AIndex := TJsonObject(ADoc).IndexOf(Seg);
  end
  else if (Item <> nil) and (not Item.IsNull) and (Item.Typ = jdtObject) and
    (Item.ObjectValue <> nil) then
    AIndex := Item.ObjectValue.IndexOf(Seg)
  else
    Exit(False);
  Result := AIndex >= 0;
end;

function JsonNameOf(ADoc: TJsonBaseObject; const APath: string; AIndex: Integer;
  out AName: string): Boolean;
var
  Item: PJsonDataValue;
  Root, Found: Boolean;
  Obj: TJsonObject;
begin
  AName := '';
  if AIndex < 0 then
    Exit(False);
  WalkRead(ADoc, APath, Item, Root, Found);
  if not Found then
    Exit(False);
  if Root then
  begin
    if not (ADoc is TJsonObject) then
      Exit(False);
    Obj := TJsonObject(ADoc);
  end
  else
  begin
    if ItemIsNull(Item) or (Item.Typ <> jdtObject) or (Item.ObjectValue = nil) then
      Exit(False);
    Obj := Item.ObjectValue;
  end;
  if AIndex >= Obj.Count then
    Exit(False);
  AName := Obj.Names[AIndex];
  Result := True;
end;

procedure JsonDeleteOf(ADoc: TJsonBaseObject; const APath: string; AIndex: Integer);
var
  Obj: TJsonObject;
begin
  if AIndex < 0 then
    raise EJsonUdr.Create('DELETEOF index must be >= 0');
  Obj := ObjectAt(ADoc, APath);
  if AIndex >= Obj.Count then
    raise EJsonUdr.CreateFmt('DELETEOF index %d out of bounds (%d) "%s"',
      [AIndex, Obj.Count, APath]);
  Obj.Delete(AIndex);
end;

function JsonExtract(ADoc: TJsonBaseObject; const APath: string; out AJson: string): Boolean;
var
  Item: PJsonDataValue;
  Root, Found: Boolean;
begin
  AJson := '';
  if APath = '' then
    raise EJsonUdr.Create('Cannot extract JSON root');
  WalkRead(ADoc, APath, Item, Root, Found);
  if not Found then
    Exit(False);
  AJson := ItemToJson(Item, True);
  JsonRemove(ADoc, APath);
  Result := True;
end;

function JsonExtractTree(ADoc: TJsonBaseObject; const APath: string;
  out ATree: TJsonBaseObject): Boolean;
var
  Item: PJsonDataValue;
  Root, Found: Boolean;
  Sink: TSink;
begin
  ATree := nil;
  if APath = '' then
    raise EJsonUdr.Create('Cannot extract JSON root');
  WalkRead(ADoc, APath, Item, Root, Found);
  if not Found then
    Exit(False);
  if ItemIsNull(Item) or not (Item.Typ in [jdtArray, jdtObject]) then
    raise EJsonUdr.Create('EXTRACTKEY expects a JSON object or array');
  WalkWrite(ADoc, APath, Sink);
  if Sink.UseIndex then
    ATree := Sink.ParentArr.Extract(Sink.Index)
  else
    ATree := Sink.ParentObj.Extract(Sink.Name);
  if ATree = nil then
    raise EJsonUdr.Create('EXTRACTKEY expects a JSON object or array');
  Result := True;
end;

end.
