{***************************************************************************}
{                                                                           }
{           Delphi Package Manager - DPM                                    }
{                                                                           }
{           Copyright � 2019 Vincent Parrett and contributors               }
{                                                                           }
{           vincent@finalbuilder.com                                        }
{           https://www.finalbuilder.com                                    }
{                                                                           }
{                                                                           }
{***************************************************************************}
{                                                                           }
{  Licensed under the Apache License, Version 2.0 (the "License");          }
{  you may not use this file except in compliance with the License.         }
{  You may obtain a copy of the License at                                  }
{                                                                           }
{      http://www.apache.org/licenses/LICENSE-2.0                           }
{                                                                           }
{  Unless required by applicable law or agreed to in writing, software      }
{  distributed under the License is distributed on an "AS IS" BASIS,        }
{  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. }
{  See the License for the specific language governing permissions and      }
{  limitations under the License.                                           }
{                                                                           }
{***************************************************************************}

unit DPM.IDE.Wizard;

interface

uses
  ToolsApi,
  Spring.Container,
  DPM.Core.Logging;

type
  TDPMWizard = class(TInterfacedObject, IOTAWizard)
  private
    FStorageNotifier : integer;
    FLogger : ILogger;
    FContainer : TContainer;
    procedure InitContainer;
  protected

    //IOTAWizard
    procedure Execute;
    function GetIDString: string;
    function GetName: string;
    function GetState: TWizardState;

    //IOTANotifier
    procedure AfterSave;
    procedure BeforeSave;
    procedure Destroyed;
    procedure Modified;
  public
    constructor Create;
    destructor Destroy;override;
  end;

implementation

uses
  System.SysUtils,
  DPM.IDE.Logger,
  DPM.Core.Init,
  DPM.IDE.ProjectStorageNotifier;

{ TDPMWizard }

procedure TDPMWizard.InitContainer;
begin
  try
    FContainer := TContainer.Create;
    FContainer.RegisterInstance<ILogger>(FLogger);
    DPM.Core.Init.InitCore(FContainer);
    FContainer.Build;
  except
    on e : Exception do
    begin

    end;
  end;
end;


procedure TDPMWizard.AfterSave;
begin

end;

procedure TDPMWizard.BeforeSave;
begin

end;

constructor TDPMWizard.Create;
var
  storageNotifier : IOTAProjectFileStorageNotifier;
begin
  FLogger := TDPMIDELogger.Create;
  InitContainer;

  storageNotifier := TDPMProjectStorageNotifier.Create(FLogger as IDPMIDELogger);
  FStorageNotifier := (BorlandIDEServices As IOTAProjectFileStorage).AddNotifier(storageNotifier);

end;

destructor TDPMWizard.Destroy;
begin
  If FStorageNotifier > -1 then
    (BorlandIDEServices As IOTAProjectFileStorage).RemoveNotifier(FStorageNotifier);

  inherited;
end;

procedure TDPMWizard.Destroyed;
begin

end;

procedure TDPMWizard.Execute;
begin
end;

function TDPMWizard.GetIDString: string;
begin
  result := 'DPM.IDE';
end;

function TDPMWizard.GetName: string;
begin
  result := 'DPM';
end;

function TDPMWizard.GetState: TWizardState;
begin
  result := [wsEnabled];
end;

procedure TDPMWizard.Modified;
begin

end;

end.
