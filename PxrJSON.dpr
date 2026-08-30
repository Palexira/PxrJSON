library PxrJSON;

{ Win64: PxrJSON.dll   Linux64: libPxrJSON.so
  EXTERNAL NAME в SQL: 'PxrJSON!SJson_GetL' — без префикса/суффикса. }

uses
  System.SysUtils,
  Firebird in 'Firebird.pas',
  JsonDataObjects in 'JsonDataObjects.pas',
  uJsonCache in 'uJsonCache.pas',
  uJsonCore in 'uJsonCore.pas',
  uJsonFb in 'uJsonFb.pas',
  uJsonUdr in 'uJsonUdr.pas',
  uJsonNodes in 'uJsonNodes.pas',
  UdrInit in 'UdrInit.pas';

exports
  firebird_udr_plugin;

begin
  IsMultiThread := True;
end.
