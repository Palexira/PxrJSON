unit uJsonFb;

interface

uses
  System.SysUtils, Firebird;

type
  TJsonXport = (jxVar, jxBlob);

const
  SQL_SHORT = 500;
  SQL_LONG = 496;
  SQL_INT64 = 580;
  SQL_DOUBLE = 480;
  SQL_FLOAT = 482;
  SQL_VARYING = 448;
  SQL_TEXT = 452;
  SQL_BLOB = 520;
  SQL_BOOLEAN = 32764;
  SQL_TIMESTAMP = 510;

procedure SetUtf8CharSet(AName: PAnsiChar; ANameSize: Cardinal);
function FbIsNull(AMsg: Pointer; AMeta: IMessageMetadata; AStatus: IStatus;
  AIndex: Cardinal): Boolean;
procedure FbSetNull(AMsg: Pointer; AMeta: IMessageMetadata; AStatus: IStatus;
  AIndex: Cardinal; ANull: Boolean);

function FbSqlType(AMeta: IMessageMetadata; AStatus: IStatus; AIndex: Cardinal): Integer;

function FbReadVarChar(AMsg: Pointer; AMeta: IMessageMetadata; AStatus: IStatus;
  AIndex: Cardinal): string;
procedure FbWriteVarChar(AMsg: Pointer; AMeta: IMessageMetadata; AStatus: IStatus;
  AIndex: Cardinal; const AValue: string);

function FbReadBlob(AMsg: Pointer; AMeta: IMessageMetadata; AStatus: IStatus;
  AContext: IExternalContext; AIndex: Cardinal): string;
procedure FbWriteBlob(AMsg: Pointer; AMeta: IMessageMetadata; AStatus: IStatus;
  AContext: IExternalContext; AIndex: Cardinal; const AValue: string);

function FbReadInt64(AMsg: Pointer; AMeta: IMessageMetadata; AStatus: IStatus;
  AIndex: Cardinal; ADefault: Int64): Int64;
function FbReadSmallint(AMsg: Pointer; AMeta: IMessageMetadata; AStatus: IStatus;
  AIndex: Cardinal; ADefault: SmallInt): SmallInt;
function FbReadDouble(AMsg: Pointer; AMeta: IMessageMetadata; AStatus: IStatus;
  AIndex: Cardinal): Double;
function FbReadBool(AMsg: Pointer; AMeta: IMessageMetadata; AStatus: IStatus;
  AIndex: Cardinal): Boolean;
function FbReadTimestamp(AMsg: Pointer; AMeta: IMessageMetadata; AStatus: IStatus;
  AIndex: Cardinal): TDateTime;

procedure FbWriteInt(AMsg: Pointer; AMeta: IMessageMetadata; AStatus: IStatus;
  AIndex: Cardinal; AValue: Integer);
procedure FbWriteInt64(AMsg: Pointer; AMeta: IMessageMetadata; AStatus: IStatus;
  AIndex: Cardinal; AValue: Int64);
procedure FbWriteDouble(AMsg: Pointer; AMeta: IMessageMetadata; AStatus: IStatus;
  AIndex: Cardinal; AValue: Double);
procedure FbWriteBool(AMsg: Pointer; AMeta: IMessageMetadata; AStatus: IStatus;
  AIndex: Cardinal; AValue: Boolean);
procedure FbWriteTimestamp(AMsg: Pointer; AMeta: IMessageMetadata; AStatus: IStatus;
  AIndex: Cardinal; AValue: TDateTime);

implementation

uses
  System.Classes, uJsonCore;

procedure SetUtf8CharSet(AName: PAnsiChar; ANameSize: Cardinal);
const
  C = UTF8String('UTF8');
begin
  if (AName = nil) or (ANameSize = 0) then
    Exit;
  FillChar(AName^, ANameSize, 0);
  if ANameSize > Cardinal(Length(C)) then
    Move(PAnsiChar(C)^, AName^, Length(C));
end;

function FbIsNull(AMsg: Pointer; AMeta: IMessageMetadata; AStatus: IStatus;
  AIndex: Cardinal): Boolean;
begin
  if AMsg = nil then
    Exit(True);
  Result := PWordBool(PByte(AMsg) + AMeta.getNullOffset(AStatus, AIndex))^;
end;

procedure FbSetNull(AMsg: Pointer; AMeta: IMessageMetadata; AStatus: IStatus;
  AIndex: Cardinal; ANull: Boolean);
begin
  PWordBool(PByte(AMsg) + AMeta.getNullOffset(AStatus, AIndex))^ := ANull;
end;

function FbSqlType(AMeta: IMessageMetadata; AStatus: IStatus; AIndex: Cardinal): Integer;
begin
  Result := Integer(AMeta.getType(AStatus, AIndex)) and not 1;
end;

function FbReadVarChar(AMsg: Pointer; AMeta: IMessageMetadata; AStatus: IStatus;
  AIndex: Cardinal): string;
var
  P: PByte;
  Len: SmallInt;
  Bytes: TBytes;
begin
  Result := '';
  if FbIsNull(AMsg, AMeta, AStatus, AIndex) then
    Exit;
  P := PByte(AMsg) + AMeta.getOffset(AStatus, AIndex);
  case FbSqlType(AMeta, AStatus, AIndex) of
    SQL_VARYING:
      begin
        Len := PSmallInt(P)^;
        if Len <= 0 then
          Exit;
        SetLength(Bytes, Len);
        Move((P + 2)^, Bytes[0], Len);
        Result := TEncoding.UTF8.GetString(Bytes);
      end;
    SQL_TEXT:
      begin
        Len := SmallInt(AMeta.getLength(AStatus, AIndex));
        SetLength(Bytes, Len);
        if Len > 0 then
          Move(P^, Bytes[0], Len);
        Result := TrimRight(TEncoding.UTF8.GetString(Bytes));
      end;
  else
    Result := '';
  end;
end;

procedure FbWriteVarChar(AMsg: Pointer; AMeta: IMessageMetadata; AStatus: IStatus;
  AIndex: Cardinal; const AValue: string);
var
  P: PByte;
  Bytes: TBytes;
  Len, MaxLen: Integer;
begin
  Bytes := TEncoding.UTF8.GetBytes(AValue);
  MaxLen := Integer(AMeta.getLength(AStatus, AIndex));
  if FbSqlType(AMeta, AStatus, AIndex) = SQL_VARYING then
  begin
    if MaxLen > 2 then
      Dec(MaxLen, 2);
    Len := Length(Bytes);
    if Len > MaxLen then
      raise EJsonUdr.Create('JSON string exceeds VARCHAR limit');
    P := PByte(AMsg) + AMeta.getOffset(AStatus, AIndex);
    PSmallInt(P)^ := Len;
    if Len > 0 then
      Move(Bytes[0], (P + 2)^, Len);
  end
  else
  begin
    Len := Length(Bytes);
    if Len > MaxLen then
      raise EJsonUdr.Create('JSON string exceeds VARCHAR limit');
    P := PByte(AMsg) + AMeta.getOffset(AStatus, AIndex);
    if MaxLen > 0 then
      FillChar(P^, MaxLen, 0);
    if Len > 0 then
      Move(Bytes[0], P^, Len);
  end;
  FbSetNull(AMsg, AMeta, AStatus, AIndex, False);
end;

function FbReadBlob(AMsg: Pointer; AMeta: IMessageMetadata; AStatus: IStatus;
  AContext: IExternalContext; AIndex: Cardinal): string;
var
  Quad: ISC_QUADPtr;
  Att: IAttachment;
  Tra: ITransaction;
  Blob: IBlob;
  Buf: array [0 .. 8191] of Byte;
  Seg: Cardinal;
  R: Integer;
  MS: TMemoryStream;
  Bytes: TBytes;
begin
  Result := '';
  if FbIsNull(AMsg, AMeta, AStatus, AIndex) then
    Exit;
  Quad := ISC_QUADPtr(PByte(AMsg) + AMeta.getOffset(AStatus, AIndex));
  Att := AContext.getAttachment(AStatus);
  Tra := AContext.getTransaction(AStatus);
  Blob := nil;
  MS := TMemoryStream.Create;
  try
    Blob := Att.openBlob(AStatus, Tra, Quad, 0, nil);
    FbException.checkException(AStatus);
    repeat
      Seg := 0;
      R := Blob.getSegment(AStatus, SizeOf(Buf), @Buf[0], @Seg);
      FbException.checkException(AStatus);
      if Seg > 0 then
        MS.WriteBuffer(Buf[0], Seg);
    until (R = IStatus.RESULT_NO_DATA) or (R = IStatus.RESULT_ERROR);
    Blob.close(AStatus);
    Blob := nil;
    if MS.Size > 0 then
    begin
      SetLength(Bytes, MS.Size);
      Move(MS.Memory^, Bytes[0], MS.Size);
      Result := TEncoding.UTF8.GetString(Bytes);
    end;
  finally
    MS.Free;
    if Blob <> nil then
      Blob.release;
    if Tra <> nil then
      Tra.release;
    if Att <> nil then
      Att.release;
  end;
end;

procedure FbWriteBlob(AMsg: Pointer; AMeta: IMessageMetadata; AStatus: IStatus;
  AContext: IExternalContext; AIndex: Cardinal; const AValue: string);
var
  Quad: ISC_QUADPtr;
  Att: IAttachment;
  Tra: ITransaction;
  Blob: IBlob;
  Bytes: TBytes;
  Off, Chunk, N: Integer;
begin
  Quad := ISC_QUADPtr(PByte(AMsg) + AMeta.getOffset(AStatus, AIndex));
  Bytes := TEncoding.UTF8.GetBytes(AValue);
  Att := AContext.getAttachment(AStatus);
  Tra := AContext.getTransaction(AStatus);
  Blob := nil;
  try
    Blob := Att.createBlob(AStatus, Tra, Quad, 0, nil);
    FbException.checkException(AStatus);
    Off := 0;
    N := Length(Bytes);
    while Off < N do
    begin
      Chunk := N - Off;
      if Chunk > 32767 then
        Chunk := 32767;
      Blob.putSegment(AStatus, Chunk, @Bytes[Off]);
      FbException.checkException(AStatus);
      Inc(Off, Chunk);
    end;
    if N = 0 then
    begin
      { empty blob is valid }
    end;
    Blob.close(AStatus);
    Blob := nil;
    FbSetNull(AMsg, AMeta, AStatus, AIndex, False);
  finally
    if Blob <> nil then
      Blob.release;
    if Tra <> nil then
      Tra.release;
    if Att <> nil then
      Att.release;
  end;
end;

function FbReadInt64(AMsg: Pointer; AMeta: IMessageMetadata; AStatus: IStatus;
  AIndex: Cardinal; ADefault: Int64): Int64;
begin
  if FbIsNull(AMsg, AMeta, AStatus, AIndex) then
    Exit(ADefault);
  case FbSqlType(AMeta, AStatus, AIndex) of
    SQL_SHORT:
      Result := PSmallInt(PByte(AMsg) + AMeta.getOffset(AStatus, AIndex))^;
    SQL_LONG:
      Result := PInteger(PByte(AMsg) + AMeta.getOffset(AStatus, AIndex))^;
    SQL_INT64:
      Result := PInt64(PByte(AMsg) + AMeta.getOffset(AStatus, AIndex))^;
  else
    Result := ADefault;
  end;
end;

function FbReadSmallint(AMsg: Pointer; AMeta: IMessageMetadata; AStatus: IStatus;
  AIndex: Cardinal; ADefault: SmallInt): SmallInt;
begin
  Result := SmallInt(FbReadInt64(AMsg, AMeta, AStatus, AIndex, ADefault));
end;

function FbReadDouble(AMsg: Pointer; AMeta: IMessageMetadata; AStatus: IStatus;
  AIndex: Cardinal): Double;
var
  P: PByte;
begin
  Result := 0;
  if FbIsNull(AMsg, AMeta, AStatus, AIndex) then
    Exit;
  P := PByte(AMsg) + AMeta.getOffset(AStatus, AIndex);
  case FbSqlType(AMeta, AStatus, AIndex) of
    SQL_DOUBLE:
      Result := PDouble(P)^;
    SQL_FLOAT:
      Result := PSingle(P)^;
  end;
end;

function FbReadBool(AMsg: Pointer; AMeta: IMessageMetadata; AStatus: IStatus;
  AIndex: Cardinal): Boolean;
begin
  Result := False;
  if FbIsNull(AMsg, AMeta, AStatus, AIndex) then
    Exit;
  Result := PByte(PByte(AMsg) + AMeta.getOffset(AStatus, AIndex))^ <> 0;
end;

function FbReadTimestamp(AMsg: Pointer; AMeta: IMessageMetadata; AStatus: IStatus;
  AIndex: Cardinal): TDateTime;
const
  CGdsDelta = 15018;
  CTicksPerDay = 86400.0 * 10000.0;
var
  P: ^ISC_TIMESTAMP;
begin
  Result := 0;
  if FbIsNull(AMsg, AMeta, AStatus, AIndex) then
    Exit;
  P := Pointer(PByte(AMsg) + AMeta.getOffset(AStatus, AIndex));
  Result := P.timestamp_date - CGdsDelta + P.timestamp_time / CTicksPerDay;
end;

procedure FbWriteInt(AMsg: Pointer; AMeta: IMessageMetadata; AStatus: IStatus;
  AIndex: Cardinal; AValue: Integer);
begin
  PInteger(PByte(AMsg) + AMeta.getOffset(AStatus, AIndex))^ := AValue;
  FbSetNull(AMsg, AMeta, AStatus, AIndex, False);
end;

procedure FbWriteInt64(AMsg: Pointer; AMeta: IMessageMetadata; AStatus: IStatus;
  AIndex: Cardinal; AValue: Int64);
begin
  PInt64(PByte(AMsg) + AMeta.getOffset(AStatus, AIndex))^ := AValue;
  FbSetNull(AMsg, AMeta, AStatus, AIndex, False);
end;

procedure FbWriteDouble(AMsg: Pointer; AMeta: IMessageMetadata; AStatus: IStatus;
  AIndex: Cardinal; AValue: Double);
begin
  PDouble(PByte(AMsg) + AMeta.getOffset(AStatus, AIndex))^ := AValue;
  FbSetNull(AMsg, AMeta, AStatus, AIndex, False);
end;

procedure FbWriteBool(AMsg: Pointer; AMeta: IMessageMetadata; AStatus: IStatus;
  AIndex: Cardinal; AValue: Boolean);
begin
  PByte(PByte(AMsg) + AMeta.getOffset(AStatus, AIndex))^ := Ord(AValue);
  FbSetNull(AMsg, AMeta, AStatus, AIndex, False);
end;

procedure FbWriteTimestamp(AMsg: Pointer; AMeta: IMessageMetadata; AStatus: IStatus;
  AIndex: Cardinal; AValue: TDateTime);
const
  CGdsDelta = 15018;
  CTicksPerDay = 86400.0 * 10000.0;
var
  P: ^ISC_TIMESTAMP;
  Ticks: Int64;
begin
  P := Pointer(PByte(AMsg) + AMeta.getOffset(AStatus, AIndex));
  P.timestamp_date := Trunc(AValue) + CGdsDelta;
  Ticks := Round(Frac(AValue) * CTicksPerDay);
  if Ticks >= Trunc(CTicksPerDay) then
  begin
    Inc(P.timestamp_date);
    Ticks := 0;
  end;
  if Ticks < 0 then
    Ticks := 0;
  P.timestamp_time := Integer(Ticks);
  FbSetNull(AMsg, AMeta, AStatus, AIndex, False);
end;

end.
