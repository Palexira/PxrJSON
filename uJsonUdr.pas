unit uJsonUdr;

interface

uses
  Firebird, uJsonFb;

type
  TJsonKind = (
    jkNewObject, jkNewArray, jkNewObjKey, jkNewArrKey, jkToJson, jkKeySize, jkParse, jkClone, jkFree,
    jkGetS, jkGetI, jkGetL, jkGetF, jkGetB, jkGetD, jkGet,
    jkGetType, jkExists, jkIsNull, jkCount, jkIndexOf, jkNameOf,
    jkSetS, jkSetI, jkSetL, jkSetF, jkSetB, jkSetD, jkSetNull, jkSet,
    jkRemove, jkClear, jkAssign, jkDeleteOf, jkSetLen, jkExtractJson, jkExtractKey,
    jkAddS, jkAddI, jkAddL, jkAddF, jkAddB, jkAddD, jkAddA, jkAddO, jkAdd,
    jkInsS, jkInsI, jkInsL, jkInsF, jkInsB, jkInsD, jkInsA, jkInsO, jkIns
  );

  TJsonUdrFactory = class(IUdrFunctionFactoryImpl)
  private
    FKind: TJsonKind;
    FXport: TJsonXport;
    FByIndex: Boolean;
  public
    constructor Create(AKind: TJsonKind; AXport: TJsonXport; AByIndex: Boolean = False);
    procedure dispose; override;
    procedure setup(AStatus: IStatus; AContext: IExternalContext;
      AMetadata: IRoutineMetadata; AInBuilder: IMetadataBuilder;
      AOutBuilder: IMetadataBuilder); override;
    function newItem(AStatus: IStatus; AContext: IExternalContext;
      AMetadata: IRoutineMetadata): IExternalFunction; override;
  end;

procedure RegisterJsonFunctions(AStatus: IStatus; APlugin: IUdrPlugin);

implementation

uses
  System.SysUtils, JsonDataObjects, uJsonCache, uJsonCore;

type
  TJsonUdrFunction = class(IExternalFunctionImpl)
  private
    FKind: TJsonKind;
    FXport: TJsonXport;
    FByIndex: Boolean;
    FMetadata: IRoutineMetadata;
    FContext: IExternalContext;
    FCache: TJsonSessionCache;
    function ReadJson(AStatus: IStatus; AContext: IExternalContext;
      AMsg: Pointer; AMeta: IMessageMetadata; AIndex: Cardinal): string;
    procedure WriteJson(AStatus: IStatus; AContext: IExternalContext;
      AMsg: Pointer; AMeta: IMessageMetadata; AIndex: Cardinal; const AText: string);
    function Mutate(const AOld: string; ADoc: TJsonBaseObject): string;
    procedure DoExecute(AStatus: IStatus; AContext: IExternalContext;
      AInMsg, AOutMsg: Pointer);
  public
    constructor Create(AKind: TJsonKind; AXport: TJsonXport; AByIndex: Boolean;
      AMetadata: IRoutineMetadata; AContext: IExternalContext;
      ACache: TJsonSessionCache);
    procedure dispose; override;
    procedure getCharSet(AStatus: IStatus; AContext: IExternalContext;
      AName: PAnsiChar; ANameSize: Cardinal); override;
    procedure execute(AStatus: IStatus; AContext: IExternalContext;
      AInMsg, AOutMsg: Pointer); override;
  end;

constructor TJsonUdrFactory.Create(AKind: TJsonKind; AXport: TJsonXport;
  AByIndex: Boolean);
begin
  inherited Create;
  FKind := AKind;
  FXport := AXport;
  FByIndex := AByIndex;
end;

procedure TJsonUdrFactory.dispose;
begin
  Destroy;
end;

procedure TJsonUdrFactory.setup(AStatus: IStatus; AContext: IExternalContext;
  AMetadata: IRoutineMetadata; AInBuilder: IMetadataBuilder;
  AOutBuilder: IMetadataBuilder);
begin
end;

function TJsonUdrFactory.newItem(AStatus: IStatus; AContext: IExternalContext;
  AMetadata: IRoutineMetadata): IExternalFunction;
var
  Cache: TJsonSessionCache;
begin
  Cache := JsonCacheAcquire(
    function(Code: Integer): Pointer
    begin
      Result := AContext.getInfo(Code);
    end,
    procedure(Code: Integer; Value: Pointer)
    begin
      AContext.setInfo(Code, Value);
    end,
    function: Integer
    begin
      Result := AContext.obtainInfoCode;
    end);
  Result := TJsonUdrFunction.Create(FKind, FXport, FByIndex, AMetadata, AContext, Cache);
end;

constructor TJsonUdrFunction.Create(AKind: TJsonKind; AXport: TJsonXport;
  AByIndex: Boolean; AMetadata: IRoutineMetadata; AContext: IExternalContext;
  ACache: TJsonSessionCache);
begin
  inherited Create;
  FKind := AKind;
  FXport := AXport;
  FByIndex := AByIndex;
  FMetadata := AMetadata;
  FContext := AContext;
  FCache := ACache;
end;

procedure TJsonUdrFunction.dispose;
begin
  if FCache <> nil then
  begin
    if FCache.Release = 0 then
    begin
      if (FContext <> nil) and (JsonCacheInfoCode <> 0) then
        FContext.setInfo(JsonCacheInfoCode, nil);
      FCache.Free;
    end;
    FCache := nil;
  end;
  Destroy;
end;

procedure TJsonUdrFunction.getCharSet(AStatus: IStatus; AContext: IExternalContext;
  AName: PAnsiChar; ANameSize: Cardinal);
begin
  SetUtf8CharSet(AName, ANameSize);
end;

function TJsonUdrFunction.ReadJson(AStatus: IStatus; AContext: IExternalContext;
  AMsg: Pointer; AMeta: IMessageMetadata; AIndex: Cardinal): string;
begin
  if FXport = jxBlob then
    Result := FbReadBlob(AMsg, AMeta, AStatus, AContext, AIndex)
  else
    Result := FbReadVarChar(AMsg, AMeta, AStatus, AIndex);
end;

procedure TJsonUdrFunction.WriteJson(AStatus: IStatus; AContext: IExternalContext;
  AMsg: Pointer; AMeta: IMessageMetadata; AIndex: Cardinal; const AText: string);
begin
  if FXport = jxBlob then
    FbWriteBlob(AMsg, AMeta, AStatus, AContext, AIndex, AText)
  else
    FbWriteVarChar(AMsg, AMeta, AStatus, AIndex, AText);
end;

function TJsonUdrFunction.Mutate(const AOld: string; ADoc: TJsonBaseObject): string;
begin
  Result := JsonDump(ADoc, True);
  FCache.Rekey(AOld, Result, ADoc);
end;

procedure TJsonUdrFunction.DoExecute(AStatus: IStatus; AContext: IExternalContext;
  AInMsg, AOutMsg: Pointer);
var
  InMeta, OutMeta: IMessageMetadata;
  Json, Path, SVal, OutText: string;
  Doc, Src, Work: TJsonBaseObject;
  Compact: SmallInt;
  IVal: Integer;
  LVal: Int64;
  FVal: Double;
  BVal: Boolean;
  DVal: TDateTime;
  Idx: Integer;
  OwnWork: Boolean;

  procedure WriteMutated;
  begin
    if IsJsonCacheKey(Json) then
      WriteJson(AStatus, AContext, AOutMsg, OutMeta, 0, Json)
    else
      WriteJson(AStatus, AContext, AOutMsg, OutMeta, 0, Mutate(Json, Doc));
  end;

  procedure WriteGetIfNull;
  begin
    case FKind of
      jkGetS, jkGetI, jkGetL, jkGetF, jkGetB, jkGetD: ;
    else
      Exit;
    end;
    if InMeta.getCount(AStatus) < 3 then
      Exit;
    if FbIsNull(AInMsg, InMeta, AStatus, 2) then
      Exit;
    case FKind of
      jkGetS:
        FbWriteVarChar(AOutMsg, OutMeta, AStatus, 0,
          FbReadVarChar(AInMsg, InMeta, AStatus, 2));
      jkGetI:
        FbWriteInt(AOutMsg, OutMeta, AStatus, 0,
          Integer(FbReadInt64(AInMsg, InMeta, AStatus, 2, 0)));
      jkGetL:
        FbWriteInt64(AOutMsg, OutMeta, AStatus, 0,
          FbReadInt64(AInMsg, InMeta, AStatus, 2, 0));
      jkGetF:
        FbWriteDouble(AOutMsg, OutMeta, AStatus, 0,
          FbReadDouble(AInMsg, InMeta, AStatus, 2));
      jkGetB:
        FbWriteBool(AOutMsg, OutMeta, AStatus, 0,
          FbReadBool(AInMsg, InMeta, AStatus, 2));
      jkGetD:
        FbWriteTimestamp(AOutMsg, OutMeta, AStatus, 0,
          FbReadTimestamp(AInMsg, InMeta, AStatus, 2));
    end;
  end;

  procedure PutNode(const ARaw: string);
  begin
    if IsJsonCacheKey(ARaw) then
    begin
      if not FCache.TryUuid(ARaw, Src) then
        raise EJsonUdr.Create('JSON key not found');
      JsonSetNode(Doc, Path, Src);
    end
    else
      JsonSetJson(Doc, Path, ARaw);
  end;

  procedure AddNode(const ARaw: string);
  begin
    if IsJsonCacheKey(ARaw) then
    begin
      if not FCache.TryUuid(ARaw, Src) then
        raise EJsonUdr.Create('JSON key not found');
      JsonAddNode(Doc, Path, Src);
    end
    else
      JsonAddJson(Doc, Path, ARaw);
  end;

  procedure InsNode(AIndex: Integer; const ARaw: string);
  begin
    if IsJsonCacheKey(ARaw) then
    begin
      if not FCache.TryUuid(ARaw, Src) then
        raise EJsonUdr.Create('JSON key not found');
      JsonInsNode(Doc, Path, AIndex, Src);
    end
    else
      JsonInsJson(Doc, Path, AIndex, ARaw);
  end;

begin
  InMeta := FMetadata.getInputMetadata(AStatus);
  OutMeta := FMetadata.getOutputMetadata(AStatus);
  try
    FbSetNull(AOutMsg, OutMeta, AStatus, 0, True);

    case FKind of
      jkNewObject:
        begin
          WriteJson(AStatus, AContext, AOutMsg, OutMeta, 0, '{}');
          Exit;
        end;
      jkNewArray:
        begin
          WriteJson(AStatus, AContext, AOutMsg, OutMeta, 0, '[]');
          Exit;
        end;
      jkNewObjKey:
        begin
          FbWriteVarChar(AOutMsg, OutMeta, AStatus, 0, FCache.NewEmpty(False));
          Exit;
        end;
      jkNewArrKey:
        begin
          FbWriteVarChar(AOutMsg, OutMeta, AStatus, 0, FCache.NewEmpty(True));
          Exit;
        end;
    end;

    if FKind = jkFree then
    begin
      if FbIsNull(AInMsg, InMeta, AStatus, 0) then
        Exit;
      FbWriteBool(AOutMsg, OutMeta, AStatus, 0,
        FCache.FreeKey(FbReadVarChar(AInMsg, InMeta, AStatus, 0)));
      Exit;
    end;

    if FbIsNull(AInMsg, InMeta, AStatus, 0) then
    begin
      WriteGetIfNull;
      Exit;
    end;
    Json := ReadJson(AStatus, AContext, AInMsg, InMeta, 0);

    if FKind = jkParse then
    begin
      FbWriteVarChar(AOutMsg, OutMeta, AStatus, 0, FCache.ParseNew(Json));
      Exit;
    end;

    if FKind = jkClone then
    begin
      FbWriteVarChar(AOutMsg, OutMeta, AStatus, 0, FCache.CloneNew(Json));
      Exit;
    end;

    if (FKind = jkToJson) or (FKind = jkKeySize) then
    begin
      Compact := FbReadSmallint(AInMsg, InMeta, AStatus, 1, 1);
      Doc := FCache.Resolve(Json);
      SVal := JsonDump(Doc, Compact <> 0);
      if FKind = jkKeySize then
        FbWriteInt(AOutMsg, OutMeta, AStatus, 0, Length(SVal))
      else
        WriteJson(AStatus, AContext, AOutMsg, OutMeta, 0, SVal);
      Exit;
    end;

    if FbIsNull(AInMsg, InMeta, AStatus, 1) then
    begin
      WriteGetIfNull;
      Exit;
    end;
    if FByIndex then
      Path := JsonIndexPath(Integer(FbReadInt64(AInMsg, InMeta, AStatus, 1, 0)))
    else
      Path := FbReadVarChar(AInMsg, InMeta, AStatus, 1);

    Doc := FCache.Resolve(Json);

    case FKind of
      jkGetS:
        if JsonGetS(Doc, Path, SVal) then
          FbWriteVarChar(AOutMsg, OutMeta, AStatus, 0, SVal)
        else
          WriteGetIfNull;
      jkGetI:
        if JsonGetI(Doc, Path, IVal) then
          FbWriteInt(AOutMsg, OutMeta, AStatus, 0, IVal)
        else
          WriteGetIfNull;
      jkGetL:
        if JsonGetL(Doc, Path, LVal) then
          FbWriteInt64(AOutMsg, OutMeta, AStatus, 0, LVal)
        else
          WriteGetIfNull;
      jkGetF:
        if JsonGetF(Doc, Path, FVal) then
          FbWriteDouble(AOutMsg, OutMeta, AStatus, 0, FVal)
        else
          WriteGetIfNull;
      jkGetB:
        if JsonGetB(Doc, Path, BVal) then
          FbWriteBool(AOutMsg, OutMeta, AStatus, 0, BVal)
        else
          WriteGetIfNull;
      jkGetD:
        if JsonGetD(Doc, Path, DVal) then
          FbWriteTimestamp(AOutMsg, OutMeta, AStatus, 0, DVal)
        else
          WriteGetIfNull;
      jkGet:
        if JsonGetNode(Doc, Path, True, OutText) then
          WriteJson(AStatus, AContext, AOutMsg, OutMeta, 0, OutText);
      jkGetType:
        if JsonGetTypeName(Doc, Path, SVal) then
          FbWriteVarChar(AOutMsg, OutMeta, AStatus, 0, SVal);
      jkExists:
        FbWriteBool(AOutMsg, OutMeta, AStatus, 0, JsonExists(Doc, Path));
      jkIsNull:
        FbWriteBool(AOutMsg, OutMeta, AStatus, 0, JsonIsNull(Doc, Path));
      jkCount:
        if JsonCount(Doc, Path, IVal) then
          FbWriteInt(AOutMsg, OutMeta, AStatus, 0, IVal);
      jkIndexOf:
        if JsonIndexOf(Doc, Path, IVal) then
          FbWriteInt(AOutMsg, OutMeta, AStatus, 0, IVal);
      jkNameOf:
        begin
          if FbIsNull(AInMsg, InMeta, AStatus, 2) then
            Exit;
          Idx := Integer(FbReadInt64(AInMsg, InMeta, AStatus, 2, 0));
          if JsonNameOf(Doc, Path, Idx, SVal) then
            FbWriteVarChar(AOutMsg, OutMeta, AStatus, 0, SVal);
        end;
      jkSetS:
        begin
          if FbIsNull(AInMsg, InMeta, AStatus, 2) then
            JsonSetNull(Doc, Path)
          else
            JsonSetS(Doc, Path, FbReadVarChar(AInMsg, InMeta, AStatus, 2));
          WriteMutated;
        end;
      jkSetI:
        begin
          if FbIsNull(AInMsg, InMeta, AStatus, 2) then
            JsonSetNull(Doc, Path)
          else
            JsonSetI(Doc, Path, Integer(FbReadInt64(AInMsg, InMeta, AStatus, 2, 0)));
          WriteMutated;
        end;
      jkSetL:
        begin
          if FbIsNull(AInMsg, InMeta, AStatus, 2) then
            JsonSetNull(Doc, Path)
          else
            JsonSetL(Doc, Path, FbReadInt64(AInMsg, InMeta, AStatus, 2, 0));
          WriteMutated;
        end;
      jkSetF:
        begin
          if FbIsNull(AInMsg, InMeta, AStatus, 2) then
            JsonSetNull(Doc, Path)
          else
            JsonSetF(Doc, Path, FbReadDouble(AInMsg, InMeta, AStatus, 2));
          WriteMutated;
        end;
      jkSetB:
        begin
          if FbIsNull(AInMsg, InMeta, AStatus, 2) then
            JsonSetNull(Doc, Path)
          else
            JsonSetB(Doc, Path, FbReadBool(AInMsg, InMeta, AStatus, 2));
          WriteMutated;
        end;
      jkSetD:
        begin
          if FbIsNull(AInMsg, InMeta, AStatus, 2) then
            JsonSetNull(Doc, Path)
          else
            JsonSetD(Doc, Path, FbReadTimestamp(AInMsg, InMeta, AStatus, 2));
          WriteMutated;
        end;
      jkSetNull:
        begin
          JsonSetNull(Doc, Path);
          WriteMutated;
        end;
      jkSet:
        begin
          if FbIsNull(AInMsg, InMeta, AStatus, 2) then
            JsonSetNull(Doc, Path)
          else
            PutNode(ReadJson(AStatus, AContext, AInMsg, InMeta, 2));
          WriteMutated;
        end;
      jkRemove:
        begin
          JsonRemove(Doc, Path);
          WriteMutated;
        end;
      jkClear:
        begin
          JsonClear(Doc, Path);
          WriteMutated;
        end;
      jkAssign:
        begin
          if FbIsNull(AInMsg, InMeta, AStatus, 2) then
            Exit;
          OutText := ReadJson(AStatus, AContext, AInMsg, InMeta, 2);
          Src := FCache.Resolve(OutText);
          if Src = Doc then
          begin
            Src := Doc.Clone;
            try
              JsonAssign(Doc, Path, Src);
            finally
              Src.Free;
            end;
          end
          else
            JsonAssign(Doc, Path, Src);
          WriteMutated;
        end;
      jkDeleteOf:
        begin
          if FbIsNull(AInMsg, InMeta, AStatus, 2) then
            Exit;
          Idx := Integer(FbReadInt64(AInMsg, InMeta, AStatus, 2, 0));
          JsonDeleteOf(Doc, Path, Idx);
          WriteMutated;
        end;
      jkSetLen:
        begin
          if FbIsNull(AInMsg, InMeta, AStatus, 2) then
            Exit;
          JsonSetLen(Doc, Path, Integer(FbReadInt64(AInMsg, InMeta, AStatus, 2, 0)));
          WriteMutated;
        end;
      jkAddS:
        begin
          if FbIsNull(AInMsg, InMeta, AStatus, 2) then
            Exit;
          JsonAddS(Doc, Path, FbReadVarChar(AInMsg, InMeta, AStatus, 2));
          WriteMutated;
        end;
      jkAddI:
        begin
          if FbIsNull(AInMsg, InMeta, AStatus, 2) then
            Exit;
          JsonAddI(Doc, Path, Integer(FbReadInt64(AInMsg, InMeta, AStatus, 2, 0)));
          WriteMutated;
        end;
      jkAddL:
        begin
          if FbIsNull(AInMsg, InMeta, AStatus, 2) then
            Exit;
          JsonAddL(Doc, Path, FbReadInt64(AInMsg, InMeta, AStatus, 2, 0));
          WriteMutated;
        end;
      jkAddF:
        begin
          if FbIsNull(AInMsg, InMeta, AStatus, 2) then
            Exit;
          JsonAddF(Doc, Path, FbReadDouble(AInMsg, InMeta, AStatus, 2));
          WriteMutated;
        end;
      jkAddB:
        begin
          if FbIsNull(AInMsg, InMeta, AStatus, 2) then
            Exit;
          JsonAddB(Doc, Path, FbReadBool(AInMsg, InMeta, AStatus, 2));
          WriteMutated;
        end;
      jkAddD:
        begin
          if FbIsNull(AInMsg, InMeta, AStatus, 2) then
            Exit;
          JsonAddD(Doc, Path, FbReadTimestamp(AInMsg, InMeta, AStatus, 2));
          WriteMutated;
        end;
      jkAddA:
        begin
          JsonAddA(Doc, Path);
          WriteMutated;
        end;
      jkAddO:
        begin
          JsonAddO(Doc, Path);
          WriteMutated;
        end;
      jkAdd:
        begin
          if FbIsNull(AInMsg, InMeta, AStatus, 2) then
            Exit;
          AddNode(ReadJson(AStatus, AContext, AInMsg, InMeta, 2));
          WriteMutated;
        end;
      jkInsS:
        begin
          if FbIsNull(AInMsg, InMeta, AStatus, 2) or FbIsNull(AInMsg, InMeta, AStatus, 3) then
            Exit;
          Idx := Integer(FbReadInt64(AInMsg, InMeta, AStatus, 2, 0));
          JsonInsS(Doc, Path, Idx, FbReadVarChar(AInMsg, InMeta, AStatus, 3));
          WriteMutated;
        end;
      jkInsI:
        begin
          if FbIsNull(AInMsg, InMeta, AStatus, 2) or FbIsNull(AInMsg, InMeta, AStatus, 3) then
            Exit;
          Idx := Integer(FbReadInt64(AInMsg, InMeta, AStatus, 2, 0));
          JsonInsI(Doc, Path, Idx, Integer(FbReadInt64(AInMsg, InMeta, AStatus, 3, 0)));
          WriteMutated;
        end;
      jkInsL:
        begin
          if FbIsNull(AInMsg, InMeta, AStatus, 2) or FbIsNull(AInMsg, InMeta, AStatus, 3) then
            Exit;
          Idx := Integer(FbReadInt64(AInMsg, InMeta, AStatus, 2, 0));
          JsonInsL(Doc, Path, Idx, FbReadInt64(AInMsg, InMeta, AStatus, 3, 0));
          WriteMutated;
        end;
      jkInsF:
        begin
          if FbIsNull(AInMsg, InMeta, AStatus, 2) or FbIsNull(AInMsg, InMeta, AStatus, 3) then
            Exit;
          Idx := Integer(FbReadInt64(AInMsg, InMeta, AStatus, 2, 0));
          JsonInsF(Doc, Path, Idx, FbReadDouble(AInMsg, InMeta, AStatus, 3));
          WriteMutated;
        end;
      jkInsB:
        begin
          if FbIsNull(AInMsg, InMeta, AStatus, 2) or FbIsNull(AInMsg, InMeta, AStatus, 3) then
            Exit;
          Idx := Integer(FbReadInt64(AInMsg, InMeta, AStatus, 2, 0));
          JsonInsB(Doc, Path, Idx, FbReadBool(AInMsg, InMeta, AStatus, 3));
          WriteMutated;
        end;
      jkInsD:
        begin
          if FbIsNull(AInMsg, InMeta, AStatus, 2) or FbIsNull(AInMsg, InMeta, AStatus, 3) then
            Exit;
          Idx := Integer(FbReadInt64(AInMsg, InMeta, AStatus, 2, 0));
          JsonInsD(Doc, Path, Idx, FbReadTimestamp(AInMsg, InMeta, AStatus, 3));
          WriteMutated;
        end;
      jkInsA:
        begin
          if FbIsNull(AInMsg, InMeta, AStatus, 2) then
            Exit;
          Idx := Integer(FbReadInt64(AInMsg, InMeta, AStatus, 2, 0));
          JsonInsA(Doc, Path, Idx);
          WriteMutated;
        end;
      jkInsO:
        begin
          if FbIsNull(AInMsg, InMeta, AStatus, 2) then
            Exit;
          Idx := Integer(FbReadInt64(AInMsg, InMeta, AStatus, 2, 0));
          JsonInsO(Doc, Path, Idx);
          WriteMutated;
        end;
      jkIns:
        begin
          if FbIsNull(AInMsg, InMeta, AStatus, 2) or FbIsNull(AInMsg, InMeta, AStatus, 3) then
            Exit;
          Idx := Integer(FbReadInt64(AInMsg, InMeta, AStatus, 2, 0));
          InsNode(Idx, ReadJson(AStatus, AContext, AInMsg, InMeta, 3));
          WriteMutated;
        end;
      jkExtractJson, jkExtractKey:
        begin
          OwnWork := not IsJsonCacheKey(Json);
          if OwnWork then
            Work := Doc.Clone
          else
            Work := Doc;
          try
            if FKind = jkExtractJson then
            begin
              if JsonExtract(Work, Path, OutText) then
                WriteJson(AStatus, AContext, AOutMsg, OutMeta, 0, OutText);
            end
            else if JsonExtractTree(Work, Path, Src) then
              FbWriteVarChar(AOutMsg, OutMeta, AStatus, 0, FCache.TakeTree(Src));
          finally
            if OwnWork then
              Work.Free;
          end;
        end;
    end;
  finally
    InMeta.release;
    OutMeta.release;
  end;
end;

procedure TJsonUdrFunction.execute(AStatus: IStatus; AContext: IExternalContext;
  AInMsg, AOutMsg: Pointer);
begin
  try
    DoExecute(AStatus, AContext, AInMsg, AOutMsg);
  except
    on E: Exception do
      FbException.catchException(AStatus, E);
  end;
end;

procedure RegisterJsonFunctions(AStatus: IStatus; APlugin: IUdrPlugin);

  procedure R(AName: PAnsiChar; AKind: TJsonKind; AXport: TJsonXport;
    AByIndex: Boolean = False);
  begin
    APlugin.registerFunction(AStatus, AName, TJsonUdrFactory.Create(AKind, AXport, AByIndex));
  end;

begin
  R('SJson_NewObject', jkNewObject, jxVar); R('BJson_NewObject', jkNewObject, jxBlob);
  R('SJson_NewArray', jkNewArray, jxVar); R('BJson_NewArray', jkNewArray, jxBlob);
  R('SJson_NewObjKey', jkNewObjKey, jxVar); R('BJson_NewObjKey', jkNewObjKey, jxBlob);
  R('SJson_NewArrKey', jkNewArrKey, jxVar); R('BJson_NewArrKey', jkNewArrKey, jxBlob);
  R('SJson_ToJson', jkToJson, jxVar); R('BJson_ToJson', jkToJson, jxBlob);
  R('SJson_KeySize', jkKeySize, jxVar); R('BJson_KeySize', jkKeySize, jxBlob);
  R('SJson_Parse', jkParse, jxVar); R('BJson_Parse', jkParse, jxBlob);
  R('SJson_Clone', jkClone, jxVar); R('BJson_Clone', jkClone, jxBlob);
  R('SJson_ExtractJson', jkExtractJson, jxVar); R('BJson_ExtractJson', jkExtractJson, jxBlob);
  R('SJson_ExtractKey', jkExtractKey, jxVar); R('BJson_ExtractKey', jkExtractKey, jxBlob);
  R('SJson_Free', jkFree, jxVar); R('BJson_Free', jkFree, jxBlob);
  R('SJson_GetS', jkGetS, jxVar); R('BJson_GetS', jkGetS, jxBlob);
  R('SJson_GetI', jkGetI, jxVar); R('BJson_GetI', jkGetI, jxBlob);
  R('SJson_GetL', jkGetL, jxVar); R('BJson_GetL', jkGetL, jxBlob);
  R('SJson_GetF', jkGetF, jxVar); R('BJson_GetF', jkGetF, jxBlob);
  R('SJson_GetB', jkGetB, jxVar); R('BJson_GetB', jkGetB, jxBlob);
  R('SJson_GetD', jkGetD, jxVar); R('BJson_GetD', jkGetD, jxBlob);
  R('SJson_Get', jkGet, jxVar); R('BJson_Get', jkGet, jxBlob);
  R('SJson_GetType', jkGetType, jxVar); R('BJson_GetType', jkGetType, jxBlob);
  R('SJson_Exists', jkExists, jxVar); R('BJson_Exists', jkExists, jxBlob);
  R('SJson_IsNull', jkIsNull, jxVar); R('BJson_IsNull', jkIsNull, jxBlob);
  R('SJson_Count', jkCount, jxVar); R('BJson_Count', jkCount, jxBlob);
  R('SJson_IndexOf', jkIndexOf, jxVar); R('BJson_IndexOf', jkIndexOf, jxBlob);
  R('SJson_NameOf', jkNameOf, jxVar); R('BJson_NameOf', jkNameOf, jxBlob);
  R('SJson_GetAtS', jkGetS, jxVar, True); R('BJson_GetAtS', jkGetS, jxBlob, True);
  R('SJson_GetAtI', jkGetI, jxVar, True); R('BJson_GetAtI', jkGetI, jxBlob, True);
  R('SJson_GetAtL', jkGetL, jxVar, True); R('BJson_GetAtL', jkGetL, jxBlob, True);
  R('SJson_GetAtF', jkGetF, jxVar, True); R('BJson_GetAtF', jkGetF, jxBlob, True);
  R('SJson_GetAtB', jkGetB, jxVar, True); R('BJson_GetAtB', jkGetB, jxBlob, True);
  R('SJson_GetAtD', jkGetD, jxVar, True); R('BJson_GetAtD', jkGetD, jxBlob, True);
  R('SJson_GetAt', jkGet, jxVar, True); R('BJson_GetAt', jkGet, jxBlob, True);
  R('SJson_GetAtType', jkGetType, jxVar, True); R('BJson_GetAtType', jkGetType, jxBlob, True);
  R('SJson_SetS', jkSetS, jxVar); R('BJson_SetS', jkSetS, jxBlob);
  R('SJson_SetI', jkSetI, jxVar); R('BJson_SetI', jkSetI, jxBlob);
  R('SJson_SetL', jkSetL, jxVar); R('BJson_SetL', jkSetL, jxBlob);
  R('SJson_SetF', jkSetF, jxVar); R('BJson_SetF', jkSetF, jxBlob);
  R('SJson_SetB', jkSetB, jxVar); R('BJson_SetB', jkSetB, jxBlob);
  R('SJson_SetD', jkSetD, jxVar); R('BJson_SetD', jkSetD, jxBlob);
  R('SJson_SetNull', jkSetNull, jxVar); R('BJson_SetNull', jkSetNull, jxBlob);
  R('SJson_Set', jkSet, jxVar); R('BJson_Set', jkSet, jxBlob);
  R('SJson_Remove', jkRemove, jxVar); R('BJson_Remove', jkRemove, jxBlob);
  R('SJson_Clear', jkClear, jxVar); R('BJson_Clear', jkClear, jxBlob);
  R('SJson_Assign', jkAssign, jxVar); R('BJson_Assign', jkAssign, jxBlob);
  R('SJson_DeleteOf', jkDeleteOf, jxVar); R('BJson_DeleteOf', jkDeleteOf, jxBlob);
  R('SJson_SetLen', jkSetLen, jxVar); R('BJson_SetLen', jkSetLen, jxBlob);
  R('SJson_SetAtS', jkSetS, jxVar, True); R('BJson_SetAtS', jkSetS, jxBlob, True);
  R('SJson_SetAtI', jkSetI, jxVar, True); R('BJson_SetAtI', jkSetI, jxBlob, True);
  R('SJson_SetAtL', jkSetL, jxVar, True); R('BJson_SetAtL', jkSetL, jxBlob, True);
  R('SJson_SetAtF', jkSetF, jxVar, True); R('BJson_SetAtF', jkSetF, jxBlob, True);
  R('SJson_SetAtB', jkSetB, jxVar, True); R('BJson_SetAtB', jkSetB, jxBlob, True);
  R('SJson_SetAtD', jkSetD, jxVar, True); R('BJson_SetAtD', jkSetD, jxBlob, True);
  R('SJson_SetAtNull', jkSetNull, jxVar, True); R('BJson_SetAtNull', jkSetNull, jxBlob, True);
  R('SJson_SetAtJ', jkSet, jxVar, True); R('BJson_SetAtJ', jkSet, jxBlob, True);
  R('SJson_RemoveAt', jkRemove, jxVar, True); R('BJson_RemoveAt', jkRemove, jxBlob, True);
  R('SJson_AddS', jkAddS, jxVar); R('BJson_AddS', jkAddS, jxBlob);
  R('SJson_AddI', jkAddI, jxVar); R('BJson_AddI', jkAddI, jxBlob);
  R('SJson_AddL', jkAddL, jxVar); R('BJson_AddL', jkAddL, jxBlob);
  R('SJson_AddF', jkAddF, jxVar); R('BJson_AddF', jkAddF, jxBlob);
  R('SJson_AddB', jkAddB, jxVar); R('BJson_AddB', jkAddB, jxBlob);
  R('SJson_AddD', jkAddD, jxVar); R('BJson_AddD', jkAddD, jxBlob);
  R('SJson_AddA', jkAddA, jxVar); R('BJson_AddA', jkAddA, jxBlob);
  R('SJson_AddO', jkAddO, jxVar); R('BJson_AddO', jkAddO, jxBlob);
  R('SJson_Add', jkAdd, jxVar); R('BJson_Add', jkAdd, jxBlob);
  R('SJson_InsS', jkInsS, jxVar); R('BJson_InsS', jkInsS, jxBlob);
  R('SJson_InsI', jkInsI, jxVar); R('BJson_InsI', jkInsI, jxBlob);
  R('SJson_InsL', jkInsL, jxVar); R('BJson_InsL', jkInsL, jxBlob);
  R('SJson_InsF', jkInsF, jxVar); R('BJson_InsF', jkInsF, jxBlob);
  R('SJson_InsB', jkInsB, jxVar); R('BJson_InsB', jkInsB, jxBlob);
  R('SJson_InsD', jkInsD, jxVar); R('BJson_InsD', jkInsD, jxBlob);
  R('SJson_InsA', jkInsA, jxVar); R('BJson_InsA', jkInsA, jxBlob);
  R('SJson_InsO', jkInsO, jxVar); R('BJson_InsO', jkInsO, jxBlob);
  R('SJson_Ins', jkIns, jxVar); R('BJson_Ins', jkIns, jxBlob);
end;

end.
