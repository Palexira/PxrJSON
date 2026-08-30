unit uJsonNodes;

interface

uses
  Firebird;

procedure RegisterJsonProcedures(AStatus: IStatus; APlugin: IUdrPlugin);

implementation

uses
  System.SysUtils, System.Generics.Collections, JsonDataObjects,
  uJsonCache, uJsonCore, uJsonFb;

type
  TJsonSelKind = (skNodes, skItems);

  TJsonNodesFactory = class(IUdrProcedureFactoryImpl)
  private
    FKind: TJsonSelKind;
    FXport: TJsonXport;
  public
    constructor Create(AKind: TJsonSelKind; AXport: TJsonXport);
    procedure dispose; override;
    procedure setup(AStatus: IStatus; AContext: IExternalContext;
      AMetadata: IRoutineMetadata; AInBuilder: IMetadataBuilder;
      AOutBuilder: IMetadataBuilder); override;
    function newItem(AStatus: IStatus; AContext: IExternalContext;
      AMetadata: IRoutineMetadata): IExternalProcedure; override;
  end;

  TJsonNodesResultSet = class(IExternalResultSetImpl)
  private
    FKind: TJsonSelKind;
    FOutMsg: Pointer;
    FOutMeta: IMessageMetadata;
    FRows: TList<TJsonNodeRow>;
    FIndex: Integer;
    procedure WriteRow(AStatus: IStatus; const ARow: TJsonNodeRow);
  public
    constructor Create(AKind: TJsonSelKind; AOutMsg: Pointer; AOutMeta: IMessageMetadata;
      ARows: TList<TJsonNodeRow>);
    procedure dispose; override;
    function fetch(AStatus: IStatus): Boolean; override;
  end;

  TJsonNodesProcedure = class(IExternalProcedureImpl)
  private
    FKind: TJsonSelKind;
    FXport: TJsonXport;
    FMetadata: IRoutineMetadata;
    FContext: IExternalContext;
    FCache: TJsonSessionCache;
    function ReadJson(AStatus: IStatus; AContext: IExternalContext;
      AMsg: Pointer; AMeta: IMessageMetadata; AIndex: Cardinal): string;
  public
    constructor Create(AKind: TJsonSelKind; AXport: TJsonXport; AMetadata: IRoutineMetadata;
      AContext: IExternalContext; ACache: TJsonSessionCache);
    procedure dispose; override;
    procedure getCharSet(AStatus: IStatus; AContext: IExternalContext;
      AName: PAnsiChar; ANameSize: Cardinal); override;
    function open(AStatus: IStatus; AContext: IExternalContext;
      AInMsg, AOutMsg: Pointer): IExternalResultSet; override;
  end;

constructor TJsonNodesFactory.Create(AKind: TJsonSelKind; AXport: TJsonXport);
begin
  inherited Create;
  FKind := AKind;
  FXport := AXport;
end;

procedure TJsonNodesFactory.dispose;
begin
  Destroy;
end;

procedure TJsonNodesFactory.setup(AStatus: IStatus; AContext: IExternalContext;
  AMetadata: IRoutineMetadata; AInBuilder: IMetadataBuilder;
  AOutBuilder: IMetadataBuilder);
begin
end;

function TJsonNodesFactory.newItem(AStatus: IStatus; AContext: IExternalContext;
  AMetadata: IRoutineMetadata): IExternalProcedure;
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
  Result := TJsonNodesProcedure.Create(FKind, FXport, AMetadata, AContext, Cache);
end;

constructor TJsonNodesResultSet.Create(AKind: TJsonSelKind; AOutMsg: Pointer;
  AOutMeta: IMessageMetadata; ARows: TList<TJsonNodeRow>);
begin
  inherited Create;
  FKind := AKind;
  FOutMsg := AOutMsg;
  FOutMeta := AOutMeta;
  FRows := ARows;
  FIndex := 0;
end;

procedure TJsonNodesResultSet.dispose;
begin
  FRows.Free;
  if FOutMeta <> nil then
    FOutMeta.release;
  Destroy;
end;

procedure TJsonNodesResultSet.WriteRow(AStatus: IStatus; const ARow: TJsonNodeRow);

  procedure WriteVal(AIndex: Cardinal);
  begin
    if ARow.Typ = 'null' then
      FbSetNull(FOutMsg, FOutMeta, AStatus, AIndex, True)
    else
      FbWriteVarChar(FOutMsg, FOutMeta, AStatus, AIndex, ARow.Val);
  end;

begin
  if FKind = skItems then
  begin
    FbWriteInt(FOutMsg, FOutMeta, AStatus, 0, ARow.LocIdx);
    FbWriteVarChar(FOutMsg, FOutMeta, AStatus, 1, ARow.Name);
    FbWriteVarChar(FOutMsg, FOutMeta, AStatus, 2, ARow.Typ);
    WriteVal(3);
  end
  else
  begin
    FbWriteInt(FOutMsg, FOutMeta, AStatus, 0, ARow.AbsIdx);
    FbWriteInt(FOutMsg, FOutMeta, AStatus, 1, ARow.LocIdx);
    FbWriteVarChar(FOutMsg, FOutMeta, AStatus, 2, ARow.Name);
    FbWriteVarChar(FOutMsg, FOutMeta, AStatus, 3, ARow.Path);
    FbWriteVarChar(FOutMsg, FOutMeta, AStatus, 4, ARow.Typ);
    WriteVal(5);
  end;
end;

function TJsonNodesResultSet.fetch(AStatus: IStatus): Boolean;
begin
  Result := False;
  try
    if (FRows = nil) or (FIndex >= FRows.Count) then
      Exit(False);
    WriteRow(AStatus, FRows[FIndex]);
    Inc(FIndex);
    Result := True;
  except
    on E: Exception do
      FbException.catchException(AStatus, E);
  end;
end;

constructor TJsonNodesProcedure.Create(AKind: TJsonSelKind; AXport: TJsonXport;
  AMetadata: IRoutineMetadata; AContext: IExternalContext; ACache: TJsonSessionCache);
begin
  inherited Create;
  FKind := AKind;
  FXport := AXport;
  FMetadata := AMetadata;
  FContext := AContext;
  FCache := ACache;
end;

procedure TJsonNodesProcedure.dispose;
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

procedure TJsonNodesProcedure.getCharSet(AStatus: IStatus; AContext: IExternalContext;
  AName: PAnsiChar; ANameSize: Cardinal);
begin
  SetUtf8CharSet(AName, ANameSize);
end;

function TJsonNodesProcedure.ReadJson(AStatus: IStatus; AContext: IExternalContext;
  AMsg: Pointer; AMeta: IMessageMetadata; AIndex: Cardinal): string;
begin
  if FXport = jxBlob then
    Result := FbReadBlob(AMsg, AMeta, AStatus, AContext, AIndex)
  else
    Result := FbReadVarChar(AMsg, AMeta, AStatus, AIndex);
end;

function TJsonNodesProcedure.open(AStatus: IStatus; AContext: IExternalContext;
  AInMsg, AOutMsg: Pointer): IExternalResultSet;
var
  InMeta, OutMeta: IMessageMetadata;
  Json, Path: string;
  FullPath: Boolean;
  Doc: TJsonBaseObject;
  Rows: TList<TJsonNodeRow>;
begin
  Result := nil;
  Rows := nil;
  InMeta := nil;
  OutMeta := nil;
  try
    InMeta := FMetadata.getInputMetadata(AStatus);
    OutMeta := FMetadata.getOutputMetadata(AStatus);
    Rows := TList<TJsonNodeRow>.Create;
    if not FbIsNull(AInMsg, InMeta, AStatus, 0) then
    begin
      Json := ReadJson(AStatus, AContext, AInMsg, InMeta, 0);
      if FbIsNull(AInMsg, InMeta, AStatus, 1) then
        Path := ''
      else
        Path := FbReadVarChar(AInMsg, InMeta, AStatus, 1);
      Doc := FCache.Resolve(Json);
      if FKind = skItems then
        JsonCollectItems(Doc, Path, Rows)
      else
      begin
        if FbIsNull(AInMsg, InMeta, AStatus, 2) then
          FullPath := True
        else
          FullPath := FbReadBool(AInMsg, InMeta, AStatus, 2);
        JsonCollectNodes(Doc, Path, FullPath, Rows);
      end;
    end;
    Result := TJsonNodesResultSet.Create(FKind, AOutMsg, OutMeta, Rows);
    OutMeta := nil;
    Rows := nil;
  except
    on E: Exception do
      FbException.catchException(AStatus, E);
  end;
  if InMeta <> nil then
    InMeta.release;
  if OutMeta <> nil then
    OutMeta.release;
  Rows.Free;
end;

procedure RegisterJsonProcedures(AStatus: IStatus; APlugin: IUdrPlugin);
begin
  APlugin.registerProcedure(AStatus, 'SJson_Nodes', TJsonNodesFactory.Create(skNodes, jxVar));
  APlugin.registerProcedure(AStatus, 'BJson_Nodes', TJsonNodesFactory.Create(skNodes, jxBlob));
  APlugin.registerProcedure(AStatus, 'SJson_Items', TJsonNodesFactory.Create(skItems, jxVar));
  APlugin.registerProcedure(AStatus, 'BJson_Items', TJsonNodesFactory.Create(skItems, jxBlob));
end;

end.
