unit UdrInit;

interface

uses
  Firebird;

function firebird_udr_plugin(AStatus: IStatus; AUnloadFlagLocal: BooleanPtr;
  AUdrPlugin: IUdrPlugin): BooleanPtr; cdecl;

implementation

uses
  uJsonUdr, uJsonNodes;

var
  myUnloadFlag: Boolean;
  theirUnloadFlag: BooleanPtr;

function firebird_udr_plugin(AStatus: IStatus; AUnloadFlagLocal: BooleanPtr;
  AUdrPlugin: IUdrPlugin): BooleanPtr; cdecl;
begin
  RegisterJsonFunctions(AStatus, AUdrPlugin);
  RegisterJsonProcedures(AStatus, AUdrPlugin);
  theirUnloadFlag := AUnloadFlagLocal;
  Result := @myUnloadFlag;
end;

initialization
  myUnloadFlag := False;

finalization
  if (theirUnloadFlag <> nil) and not myUnloadFlag then
    theirUnloadFlag^ := True;

end.
