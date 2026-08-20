unit uRavTool;

interface

function RunRavTool: Integer;

implementation

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.TypInfo, Vcl.Forms,
  RvDefine, RvClass, RvProj, RvUtil, RvCmHuff,
  RvLDCompiler, RvLESystem, RvLEModule, RvLESource,
  RvCsRpt, RvCsStd, RvCsData, RvCsBars, RvCsDraw,
  RvData, RvDataLink, RvDirectDataView, RvDriverDataView,
  RvDatabase, RvDataField, RvSecurity, RvToolEvents;

var
  Saida: TStreamWriter;
  LastErr: string;
  PMAtual: TRaveProjectManager;  // usado por AplicaValor para resolver referencias

function AchaComp(PM: TRaveProjectManager; const Nome: string): TComponent; forward;

procedure Cap(CompileStatus: TRaveCompileStatus);
begin
  if Assigned(CompileStatus) then
    LastErr := Format('linha %d, col %d: %s',
      [CompileStatus.ErrorLine, CompileStatus.ErrorCol, CompileStatus.ErrorMsg])
  else
    LastErr := '';
end;

procedure Diz(const S: string);
begin
  Writeln(S);
  if Assigned(Saida) then
  begin
    Saida.WriteLine(S);
    Saida.Flush;
  end;
end;

// Os modulos de sistema .rvc precisam estar ao lado do exe (mesma logica do
// RaveBatchCompile); copia do diretorio de instalacao no primeiro uso.
procedure CopiaRvc;
var
  ExeDir, BinDir: string;
  SR: TSearchRec;
begin
  ExeDir := IncludeTrailingPathDelimiter(ExtractFilePath(Application.ExeName));
  if FileExists(ExeDir + 'System.rvc') then Exit;
  BinDir := 'C:\Program Files (x86)\Nevrona\Rave2025\Bin\';
  if FindFirst(BinDir + '*.rvc', faAnyFile and not faDirectory, SR) = 0 then
  begin
    repeat
      if (SR.Attr and faDirectory) = 0 then
        CopyFile(PChar(BinDir + SR.Name), PChar(ExeDir + SR.Name), False);
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
end;

function ValorProp(Inst: TObject; PropInfo: PPropInfo): string;
var
  Tipo: PTypeInfo;
begin
  Result := '';
  Tipo := PropInfo^.PropType^;
  try
    case Tipo^.Kind of
      tkInteger:
        Result := IntToStr(GetOrdProp(Inst, PropInfo));
      tkEnumeration:
        Result := GetEnumProp(Inst, PropInfo);
      tkFloat:
        Result := FormatFloat('0.####', GetFloatProp(Inst, PropInfo));
      tkString, tkLString, tkWString, tkUString:
        Result := GetStrProp(Inst, PropInfo);
      tkSet:
        Result := GetSetProp(Inst, PropInfo, True);
      tkClass:
        begin
          if GetObjectProp(Inst, PropInfo) is TComponent then
            Result := '<' + TComponent(GetObjectProp(Inst, PropInfo)).Name + '>'
          else if GetObjectProp(Inst, PropInfo) is TStrings then
            Result := '[' + StringReplace(Trim(TStrings(GetObjectProp(Inst, PropInfo)).Text),
                              sLineBreak, ' | ', [rfReplaceAll]) + ']'
          else if GetObjectProp(Inst, PropInfo) <> nil then
            Result := '(' + GetObjectProp(Inst, PropInfo).ClassName + ')'
          else
            Result := '';
        end;
    else
      Result := '';
    end;
  except
    on E: Exception do
      Result := '<erro: ' + E.Message + '>';
  end;
end;

// Propriedades que poluem o dump sem ajudar a identificar o componente.
function PropIgnorada(const Nome: string): Boolean;
const
  Ignorar: array[0..13] of string = (
    'Cursor', 'Tag', 'MirrorOverride', 'MirrorPoint', 'Anchor',
    'OnBeforeReport', 'OnAfterReport', 'OnBeforePrint', 'OnAfterPrint',
    'Storage', 'DevLocked', 'Locked', 'PrintDepth', 'ControlStyle');
var
  I: Integer;
begin
  Result := False;
  for I := Low(Ignorar) to High(Ignorar) do
    if SameText(Nome, Ignorar[I]) then
      Exit(True);
end;

procedure DumpProps(Comp: TComponent; const Indent: string);
var
  Lista: PPropList;
  Qtd, I: Integer;
  Nome, Valor, Linha: string;
begin
  Qtd := GetPropList(Comp.ClassInfo, tkProperties, nil);
  if Qtd = 0 then Exit;
  GetMem(Lista, Qtd * SizeOf(Pointer));
  try
    GetPropList(Comp.ClassInfo, tkProperties, Lista);
    Linha := '';
    for I := 0 to Qtd - 1 do
    begin
      Nome := string(Lista^[I]^.Name);
      if PropIgnorada(Nome) then Continue;
      Valor := ValorProp(Comp, Lista^[I]);
      if (Valor = '') or (Valor = '0') or (Valor = '[]') then Continue;
      if Linha <> '' then Linha := Linha + '  ';
      Linha := Linha + Nome + '=' + Valor;
      if Length(Linha) > 150 then
      begin
        Diz(Indent + '    ' + Linha);
        Linha := '';
      end;
    end;
    if Linha <> '' then
      Diz(Indent + '    ' + Linha);
  finally
    FreeMem(Lista);
  end;
end;

procedure DumpComp(Comp: TComponent; Nivel: Integer);
var
  I: Integer;
  Indent, Cab: string;
begin
  if Comp = nil then Exit;
  Indent := StringOfChar(' ', Nivel * 2);
  Cab := Indent + '- ' + Comp.ClassName;
  if Comp.Name <> '' then
    Cab := Cab + ' "' + Comp.Name + '"';
  Diz(Cab);
  try
    DumpProps(Comp, Indent);
  except
    on E: Exception do
      Diz(Indent + '    <falha ao ler propriedades: ' + E.Message + '>');
  end;
  for I := 0 to Comp.ComponentCount - 1 do
    DumpComp(Comp.Components[I], Nivel + 1);
end;

procedure DumpLista(const Titulo: string; Lista: TList);
var
  I: Integer;
begin
  Diz('');
  Diz('=== ' + Titulo + ' (' + IntToStr(Lista.Count) + ') ===');
  for I := 0 to Lista.Count - 1 do
    DumpComp(TComponent(Lista[I]), 0);
end;

// Mesmo auto-fix do RaveBatchCompile: renomeia relatorio cujo Name colide com o
// nome do projeto/dataview/pagina, senao o Compile falha com Error #15.
function ResolverColisaoNomes(PM: TRaveProjectManager): Integer;
var
  Usados: TStringList;
  i, k: Integer;
  Rep: TRaveProjectItem;
  Base, Novo, FullAnterior: string;
begin
  Result := 0;
  Usados := TStringList.Create;
  try
    Usados.CaseSensitive := False;
    Usados.Add(PM.Name);
    for i := 0 to PM.DataObjectList.Count - 1 do
      Usados.Add(TRaveProjectItem(PM.DataObjectList[i]).Name);
    for i := 0 to PM.GlobalPageList.Count - 1 do
      Usados.Add(TRaveProjectItem(PM.GlobalPageList[i]).Name);
    for i := 0 to PM.ReportList.Count - 1 do
    begin
      Rep := TRaveProjectItem(PM.ReportList[i]);
      if Usados.IndexOf(Rep.Name) >= 0 then
      begin
        Base := Rep.Name + 'REL';
        Novo := Base;
        k := 0;
        while Usados.IndexOf(Novo) >= 0 do
        begin
          Inc(k);
          Novo := Base + IntToStr(k);
        end;
        FullAnterior := Rep.FullName;
        Rep.Name := Novo;
        Rep.FullName := FullAnterior;
        Inc(Result);
      end;
      Usados.Add(Rep.Name);
    end;
  finally
    Usados.Free;
  end;
end;

function AbreProjeto(const Arquivo: string; out Owner: TRaveContainerControl;
  out PM: TRaveProjectManager): Boolean;
begin
  Result := False;
  if not FileExists(Arquivo) then
  begin
    Writeln(ErrOutput, 'ERRO: arquivo nao encontrado: ' + Arquivo);
    Exit;
  end;
  CopiaRvc;
  SetCurrentDir(ExtractFilePath(Application.ExeName));
  CallRegisters('*');
  CompileStatusProc := Cap;

  Owner := TRaveContainerControl.Create(nil);
  PM := TRaveProjectManager.Create(Owner);
  PM.Name := 'RaveProject';
  RvProj.ProjectManager := PM;
  PM.FileName := Arquivo;
  PM.Load;
  ResolverColisaoNomes(PM);
  PMAtual := PM;
  Result := True;
end;

procedure FechaProjeto(Owner: TRaveContainerControl);
begin
  RvProj.ProjectManager := nil;
  Owner.Free;
end;

function GravaProjeto(PM: TRaveProjectManager; const Arquivo: string): Boolean;
var
  Backup: string;
begin
  Backup := Arquivo + '.bak-' + FormatDateTime('yyyymmdd-hhnnss', Now);
  CopyFile(PChar(Arquivo), PChar(Backup), False);
  Diz('Backup: ' + ExtractFileName(Backup));

  LastErr := '';
  if not PM.Compile then
  begin
    Writeln(ErrOutput, 'ERRO: projeto nao compila, nada foi gravado. ' + LastErr);
    Exit(False);
  end;
  PM.Save;
  System.SysUtils.DeleteFile(ChangeFileExt(Arquivo, '.~ra'));
  Diz('Gravado: ' + ExtractFileName(Arquivo));
  Result := True;
end;

function AchaComp(PM: TRaveProjectManager; const Nome: string): TComponent;
var
  Achado: TComponent;

  procedure Busca(Comp: TComponent);
  var
    I: Integer;
  begin
    if (Comp = nil) or (Achado <> nil) then Exit;
    if SameText(Comp.Name, Nome) then
    begin
      Achado := Comp;
      Exit;
    end;
    for I := 0 to Comp.ComponentCount - 1 do
      Busca(Comp.Components[I]);
  end;

  procedure BuscaLista(Lista: TList);
  var
    I: Integer;
  begin
    for I := 0 to Lista.Count - 1 do
      Busca(TComponent(Lista[I]));
  end;

begin
  Achado := nil;
  BuscaLista(PM.ReportList);
  if Achado = nil then BuscaLista(PM.GlobalPageList);
  if Achado = nil then BuscaLista(PM.DataObjectList);
  Result := Achado;
end;

procedure AplicaValor(Comp: TComponent; const Prop, Valor: string);
var
  PropInfo: PPropInfo;
  Alvo: TComponent;
begin
  PropInfo := GetPropInfo(Comp.ClassInfo, Prop);
  if PropInfo = nil then
    raise Exception.Create('propriedade "' + Prop + '" nao existe em ' + Comp.ClassName);

  case PropInfo^.PropType^^.Kind of
    tkInteger:
      SetOrdProp(Comp, PropInfo, StrToInt(Valor));
    tkEnumeration:
      SetEnumProp(Comp, PropInfo, Valor);
    tkFloat:
      SetFloatProp(Comp, PropInfo, StrToFloat(StringReplace(Valor, '.', FormatSettings.DecimalSeparator, [rfReplaceAll])));
    tkString, tkLString, tkWString, tkUString:
      SetStrProp(Comp, PropInfo, Valor);
    tkSet:
      SetSetProp(Comp, PropInfo, Valor);
    tkClass:
      begin
        // referencia a outro componente do projeto (DataView, Controller, ...)
        Alvo := AchaComp(PMAtual, Valor);
        if Alvo = nil then
          raise Exception.Create('componente "' + Valor + '" nao encontrado para a propriedade ' + Prop);
        SetObjectProp(Comp, PropInfo, Alvo);
      end;
  else
    raise Exception.Create('tipo da propriedade "' + Prop + '" nao suportado');
  end;
end;

function CmdDump(const Arquivo, ArqSaida: string): Integer;
var
  PM: TRaveProjectManager;
  Owner: TRaveContainerControl;
begin
  if not AbreProjeto(Arquivo, Owner, PM) then Exit(3);
  try
    if ArqSaida <> '' then
      Saida := TStreamWriter.Create(ArqSaida, False, TEncoding.UTF8);
    try
      Diz('Arquivo : ' + Arquivo);
      Diz('Projeto : ' + PM.Name + '  Versao=' + IntToStr(PM.Version) +
          '  Unidades=' + IntToStr(Ord(PM.Units)));
      DumpLista('DATA OBJECTS', PM.DataObjectList);
      DumpLista('PAGINAS GLOBAIS', PM.GlobalPageList);
      DumpLista('RELATORIOS', PM.ReportList);
      Diz('');
      Diz('=== FIM ===');
    finally
      FreeAndNil(Saida);
    end;
    Result := 0;
  finally
    FechaProjeto(Owner);
  end;
end;

function CmdSet(const Arquivo, NomeComp, Prop, Valor: string): Integer;
var
  PM: TRaveProjectManager;
  Owner: TRaveContainerControl;
  Comp: TComponent;
begin
  if not AbreProjeto(Arquivo, Owner, PM) then Exit(3);
  try
    Comp := AchaComp(PM, NomeComp);
    if Comp = nil then
    begin
      Writeln(ErrOutput, 'ERRO: componente "' + NomeComp + '" nao encontrado');
      Exit(2);
    end;
    AplicaValor(Comp, Prop, Valor);
    Diz(Comp.ClassName + ' "' + Comp.Name + '": ' + Prop + ' := ' + Valor);
    if GravaProjeto(PM, Arquivo) then Result := 0 else Result := 3;
  finally
    FechaProjeto(Owner);
  end;
end;

function CmdDel(const Arquivo: string; Nomes: TStrings): Integer;
var
  PM: TRaveProjectManager;
  Owner: TRaveContainerControl;
  Comp: TComponent;
  I, Removidos: Integer;
begin
  if not AbreProjeto(Arquivo, Owner, PM) then Exit(3);
  try
    Removidos := 0;
    for I := 0 to Nomes.Count - 1 do
    begin
      Comp := AchaComp(PM, Nomes[I]);
      if Comp = nil then
      begin
        Writeln(ErrOutput, 'AVISO: componente "' + Nomes[I] + '" nao encontrado');
        Continue;
      end;
      Diz('Removendo ' + Comp.ClassName + ' "' + Comp.Name + '"');
      Comp.Free;
      Inc(Removidos);
    end;
    if Removidos = 0 then
    begin
      Writeln(ErrOutput, 'ERRO: nenhum componente removido, nada gravado');
      Exit(2);
    end;
    if GravaProjeto(PM, Arquivo) then Result := 0 else Result := 3;
  finally
    FechaProjeto(Owner);
  end;
end;

function CmdCopy(const Arquivo, Origem, NovoNome: string; Ajustes: TStrings): Integer;
var
  PM: TRaveProjectManager;
  Owner: TRaveContainerControl;
  Comp, Novo: TComponent;
  Fonte: TMemoryStream;
  NomeOrig: string;
  I, P: Integer;
begin
  if not AbreProjeto(Arquivo, Owner, PM) then Exit(3);
  try
    Comp := AchaComp(PM, Origem);
    if Comp = nil then
    begin
      Writeln(ErrOutput, 'ERRO: componente "' + Origem + '" nao encontrado');
      Exit(2);
    end;
    if AchaComp(PM, NovoNome) <> nil then
    begin
      Writeln(ErrOutput, 'ERRO: ja existe componente chamado "' + NovoNome + '"');
      Exit(2);
    end;

    Novo := TComponentClass(Comp.ClassType).Create(Comp.Owner);
    Fonte := TMemoryStream.Create;
    try
      // O stream carrega o Name; para nao colidir com o original na leitura,
      // grava-se ja com o nome novo e restaura-se o original em seguida.
      NomeOrig := Comp.Name;
      Comp.Name := NovoNome;
      try
        Fonte.WriteComponent(Comp);
      finally
        Comp.Name := NomeOrig;
      end;
      Fonte.Position := 0;
      Fonte.ReadComponent(Novo);
    finally
      Fonte.Free;
    end;
    if (Comp is TRaveComponent) and (Novo is TRaveComponent) then
      TRaveComponent(Novo).Parent := TRaveComponent(Comp).Parent;

    for I := 0 to Ajustes.Count - 1 do
    begin
      P := Pos('=', Ajustes[I]);
      if P > 1 then
        AplicaValor(Novo, Copy(Ajustes[I], 1, P - 1), Copy(Ajustes[I], P + 1, MaxInt));
    end;

    Diz('Criado ' + Novo.ClassName + ' "' + Novo.Name + '" a partir de "' + Origem + '"');
    if GravaProjeto(PM, Arquivo) then Result := 0 else Result := 3;
  finally
    FechaProjeto(Owner);
  end;
end;

function CmdAdd(const Arquivo, Classe, NovoNome, NomePai: string; Ajustes: TStrings): Integer;
var
  PM: TRaveProjectManager;
  Owner: TRaveContainerControl;
  Pai, Novo: TComponent;
  ClasseComp: TPersistentClass;
  I, P: Integer;
begin
  if not AbreProjeto(Arquivo, Owner, PM) then Exit(3);
  try
    Pai := AchaComp(PM, NomePai);
    if Pai = nil then
    begin
      Writeln(ErrOutput, 'ERRO: componente pai "' + NomePai + '" nao encontrado');
      Exit(2);
    end;
    if AchaComp(PM, NovoNome) <> nil then
    begin
      Writeln(ErrOutput, 'ERRO: ja existe componente chamado "' + NovoNome + '"');
      Exit(2);
    end;
    ClasseComp := GetClass(Classe);
    if (ClasseComp = nil) or not ClasseComp.InheritsFrom(TComponent) then
    begin
      Writeln(ErrOutput, 'ERRO: classe "' + Classe + '" nao registrada');
      Exit(2);
    end;

    Novo := TComponentClass(ClasseComp).Create(Pai.Owner);
    Novo.Name := NovoNome;
    if (Novo is TRaveComponent) and (Pai is TRaveComponent) then
      TRaveComponent(Novo).Parent := TRaveComponent(Pai);

    for I := 0 to Ajustes.Count - 1 do
    begin
      P := Pos('=', Ajustes[I]);
      if P > 1 then
        AplicaValor(Novo, Copy(Ajustes[I], 1, P - 1), Copy(Ajustes[I], P + 1, MaxInt));
    end;

    Diz('Criado ' + Novo.ClassName + ' "' + Novo.Name + '" dentro de "' + NomePai + '"');
    if GravaProjeto(PM, Arquivo) then Result := 0 else Result := 3;
  finally
    FechaProjeto(Owner);
  end;
end;

procedure Ajuda;
begin
  Writeln('ravtool - inspeciona e edita arquivos .rav do Rave 2025');
  Writeln('');
  Writeln('  ravtool dump <arq.rav> [saida.txt]');
  Writeln('  ravtool set  <arq.rav> <Componente> <Propriedade> <Valor>');
  Writeln('  ravtool del  <arq.rav> <Componente> [<Componente> ...]');
  Writeln('  ravtool copy <arq.rav> <Origem> <NovoNome> [Prop=Valor ...]');
  Writeln('  ravtool add  <arq.rav> <Classe> <NovoNome> <Pai> [Prop=Valor ...]');
end;

function RunRavTool: Integer;
var
  Cmd: string;
  Lista: TStringList;
  I: Integer;
begin
  if ParamCount < 2 then
  begin
    Ajuda;
    Exit(1);
  end;
  Cmd := LowerCase(ParamStr(1));

  if Cmd = 'dump' then
    Result := CmdDump(ParamStr(2), ParamStr(3))
  else if Cmd = 'set' then
  begin
    if ParamCount < 5 then begin Ajuda; Exit(1); end;
    Result := CmdSet(ParamStr(2), ParamStr(3), ParamStr(4), ParamStr(5));
  end
  else if Cmd = 'del' then
  begin
    Lista := TStringList.Create;
    try
      for I := 3 to ParamCount do
        Lista.Add(ParamStr(I));
      if Lista.Count = 0 then begin Ajuda; Exit(1); end;
      Result := CmdDel(ParamStr(2), Lista);
    finally
      Lista.Free;
    end;
  end
  else if Cmd = 'add' then
  begin
    if ParamCount < 5 then begin Ajuda; Exit(1); end;
    Lista := TStringList.Create;
    try
      for I := 6 to ParamCount do
        Lista.Add(ParamStr(I));
      Result := CmdAdd(ParamStr(2), ParamStr(3), ParamStr(4), ParamStr(5), Lista);
    finally
      Lista.Free;
    end;
  end
  else if Cmd = 'copy' then
  begin
    if ParamCount < 4 then begin Ajuda; Exit(1); end;
    Lista := TStringList.Create;
    try
      for I := 5 to ParamCount do
        Lista.Add(ParamStr(I));
      Result := CmdCopy(ParamStr(2), ParamStr(3), ParamStr(4), Lista);
    finally
      Lista.Free;
    end;
  end
  else
  begin
    Ajuda;
    Result := 1;
  end;
end;

end.
