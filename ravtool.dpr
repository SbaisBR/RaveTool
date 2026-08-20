program ravtool;

// Ferramenta de linha de comando para INSPECIONAR e EDITAR arquivos .RAV
// (Rave 2025) sem abrir o designer. Usa a mesma API do RaveBatchCompile
// (TRaveProjectManager: Load / Save), navegando os componentes por RTTI.
//
// Uso:
//   ravtool dump <arquivo.rav> [saida.txt]
//       Lista a arvore completa (DataViews, paginas globais, relatorios) com
//       as propriedades publicadas de cada componente.
//
//   ravtool set <arquivo.rav> <Componente> <Propriedade> <Valor>
//       Altera uma propriedade publicada de um componente e grava.
//
//   ravtool del <arquivo.rav> <Componente> [<Componente> ...]
//       Remove componentes e grava.
//
//   ravtool copy <arquivo.rav> <Origem> <NovoNome> [<Prop=Valor> ...]
//       Duplica um componente na mesma pagina/banda, aplicando ajustes.
//
// Toda gravacao passa por Compile antes de Save (igual RaveBatchCompile) e
// cria backup .bak-AAAAMMDD-HHNNSS ao lado do arquivo.

{$APPTYPE CONSOLE}

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.TypInfo,
  Vcl.Forms,
  uRavTool in 'uRavTool.pas';

begin
  try
    ExitCode := RunRavTool;
  except
    on E: Exception do
    begin
      Writeln(ErrOutput, 'ERRO: ', E.ClassName, ': ', E.Message);
      ExitCode := 3;
    end;
  end;
end.
