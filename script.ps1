#Requires -Version 5.1
# Sistema de Busca de Fichas com Interface WPF Moderna

# Adicionar assemblies necessários
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- CONFIGURAÇÃO OBRATÓRIA ---
$script:GhostscriptExePath = "C:\Program Files\gs\gs10.06.0\bin\gswin64c.exe"  # Versão console (sem janela)
# --- FIM DA CONFIGURAÇÃO ---

# Configurações globais
$script:CaminhoBase = "\\192.168.20.100\TRABALHO\TRANSITO\FICHAS INDISPONIBILIDADE NOVAS RENOMEADAS"
$script:PastaIgnorar = "\\192.168.20.100\TRABALHO\TRANSITO\FICHAS INDISPONIBILIDADE NOVAS RENOMEADAS\INDICADOR REAL"  # Por padrão ignora INDICADOR REAL (toggle altera isso)
$script:PastaTemporaria = $null
$script:ArquivosEncontrados = @()
$script:BuscaEmAndamento = $false
$script:TemaAtual = "Light"
$script:job = $null # Variavel para armazenar o Job
$script:timer = $null # Variavel para o timer
$script:FileCountFile = $null # Arquivo temporário para compartilhar contagem com o job

# Funções Auxiliares (Escopo Global)
function Remove-Acentos {
    param([string]$Texto)
    $comAcentos = "ÀÁÂÃÄÅàáâãäåÈÉÊËèéêëÌÍÎÏìíîïÒÓÔÕÖòóôõöÙÚÛÜùúûüÝýÿÑñÇç"
    $semAcentos = "AAAAAAaaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuYyyNnCc"
    $resultado = $Texto
    for ($i = 0; $i -lt $comAcentos.Length; $i++) {
        $resultado = $resultado.Replace($comAcentos[$i], $semAcentos[$i])
    }
    return $resultado
}

function Format-NomeBusca {
    param([string]$NomeDigitado)
    $nome = $NomeDigitado.Trim() -replace '\s+', ' '
    $nome = Remove-Acentos -Texto $nome
    $nome = $nome.ToUpper()
    $nome = $nome.Replace(' ', '_')
    return $nome
}

function Test-IsDocumento {
    param([string]$Texto)
    # Remove todos os caracteres não numéricos
    $apenasDigitos = $Texto -replace '[^0-9]', ''

    # Verifica se tem apenas dígitos após remover formatação
    # CPF tem 11 dígitos, CNPJ tem 14
    if ($apenasDigitos.Length -eq 11 -or $apenasDigitos.Length -eq 14) {
        # Verifica se a string original tinha pelo menos 50% de dígitos (para evitar falsos positivos)
        $porcentagemDigitos = ($apenasDigitos.Length / $Texto.Length) * 100
        return $porcentagemDigitos -ge 50
    }
    return $false
}

function Format-NumeroDocumento {
    param([string]$Texto)
    # Remove tudo que não é dígito (pontos, traços, barras, espaços, etc)
    $numeroLimpo = $Texto -replace '[^0-9]', ''
    return $numeroLimpo
}

function New-PastaTemporaria {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $downloadsPath = [Environment]::GetFolderPath('UserProfile') + "\Downloads"
    $pastaTemp = Join-Path $downloadsPath "BuscaFichas_$timestamp"
    try {
        New-Item -Path $pastaTemp -ItemType Directory -Force | Out-Null
        return $pastaTemp
    }
    catch {
        # Write-Error "Erro ao criar pasta temporária: $_"
        return $null
    }
}

function Remove-PastaTemporaria {
    param([string]$Caminho)
    if ($Caminho -and (Test-Path $Caminho)) {
        try {
            if ($script:imgPreview -and $script:imgPreview.Source) {
                 $script:imgPreview.Source = $null 
                 [GC]::Collect()
            }
            Remove-Item -Path $Caminho -Recurse -Force -ErrorAction Stop
            return $true
        } catch {
            Start-Sleep -Milliseconds 500
            try {
                Remove-Item -Path $Caminho -Recurse -Force -ErrorAction Stop
                return $true
            }
            catch {
                # Write-Error "Não foi possível remover '$Caminho': $_"
                return $false
            }
        }
    }
    return $true
}

function Generate-PdfPreviewImage {
    param([string]$PdfPath)

    if (-not (Test-Path $script:GhostscriptExePath)) {
        # Write-Error "Ghostscript não encontrado."
        return $null
    }

    # Usar nome único baseado no arquivo PDF + timestamp para evitar cache
    $pdfBaseName = [System.IO.Path]::GetFileNameWithoutExtension($PdfPath)
    $uniqueId = [DateTime]::Now.Ticks
    $baseOutputName = "preview_${pdfBaseName}_${uniqueId}_page"
    $outputPattern = Join-Path $script:PastaTemporaria ($baseOutputName + "_%d.png")
    $finalStitchedPath = Join-Path $script:PastaTemporaria "preview_${pdfBaseName}_${uniqueId}.png"

    # Limpar previews antigos (manter apenas os 3 mais recentes)
    try {
        $oldPreviews = Get-ChildItem -Path $script:PastaTemporaria -Filter "preview_*.png" | Sort-Object LastWriteTime -Descending | Select-Object -Skip 3
        $oldPreviews | Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {}

    $arguments = @(
        "-dNOPAUSE", "-dBATCH", "-dSAFER", "-dQUIET", 
        "-sDEVICE=png16m", "-r150", 
        "-dFirstPage=1", "-dLastPage=2", 
        "-sOutputFile=`"$outputPattern`"", "`"$PdfPath`""
    )

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $script:GhostscriptExePath
        $psi.Arguments = $arguments -join " "
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi

        # Iniciar o processo sem janela visível
        [void]$proc.Start()

        # Ocultar a janela imediatamente após iniciar (garantia extra)
        try {
            if (-not ([System.Management.Automation.PSTypeName]'WindowHelper').Type) {
                Add-Type @"
                    using System;
                    using System.Runtime.InteropServices;
                    public class WindowHelper {
                        [DllImport("user32.dll")]
                        public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
                        public const int SW_HIDE = 0;
                    }
"@
            }
            # Aguardar um pouco para garantir que a janela foi criada
            Start-Sleep -Milliseconds 50
            $proc.Refresh()
            if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
                [WindowHelper]::ShowWindow($proc.MainWindowHandle, [WindowHelper]::SW_HIDE)
            }
        } catch {}

        $proc.WaitForExit()

        if ($proc.ExitCode -ne 0) { return $null }
    } catch { return $null }

    $generatedFiles = Get-ChildItem -Path $script:PastaTemporaria -Filter ($baseOutputName + "_*.png") | Sort-Object Name
    if ($generatedFiles.Count -eq 0) { return $null }

    $imageList = [System.Collections.Generic.List[System.Drawing.Image]]::new()
    $totalHeight = 0
    $maxWidth = 0
    $canvas = $null
    $graphics = $null

    try {
        foreach ($file in $generatedFiles) {
            $fileStream = New-Object System.IO.FileStream($file.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read)
            $memoryStream = New-Object System.IO.MemoryStream
            $fileStream.CopyTo($memoryStream)
            $fileStream.Close(); $fileStream.Dispose()
            $memoryStream.Position = 0
            $img = [System.Drawing.Image]::FromStream($memoryStream)
            $memoryStream.Dispose()

            $imageList.Add($img)
            $totalHeight += $img.Height
            if ($img.Width -gt $maxWidth) { $maxWidth = $img.Width }
        }

        if ($maxWidth -eq 0 -or $totalHeight -eq 0) { throw "Dimensões inválidas." }

        $canvas = New-Object System.Drawing.Bitmap($maxWidth, $totalHeight)
        $graphics = [System.Drawing.Graphics]::FromImage($canvas)
        $graphics.Clear([System.Drawing.Color]::White)

        $currentY = 0
        foreach ($img in $imageList) {
            $graphics.DrawImage($img, 0, $currentY)
            $currentY += $img.Height
        }

        $canvas.Save($finalStitchedPath, [System.Drawing.Imaging.ImageFormat]::Png)
        return $finalStitchedPath
    } catch {
        return $null
    } finally {
        if ($graphics) { $graphics.Dispose() }
        if ($canvas) { $canvas.Dispose() }
        foreach ($img in $imageList) { $img.Dispose() }
        foreach ($file in $generatedFiles) { try { Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue } catch {} }
    }
}


# XAML 
[xml]$xaml = @"
<Window 
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Sistema de Busca de Fichas - Ultra Modern UI"
    Height="900" Width="1400"
    WindowStartupLocation="CenterScreen"
    WindowState="Maximized"
    Background="Transparent"
    AllowsTransparency="True"
    WindowStyle="None">
    
    <Window.Resources>
        <SolidColorBrush x:Key="LightSolidDark" Color="#3a3a3a"/>
        <SolidColorBrush x:Key="LightSolidDarkAlt" Color="#4a4a4a"/>
        <SolidColorBrush x:Key="LightCreamBackground" Color="#FAF7F2"/>
        <LinearGradientBrush x:Key="LightBackground" StartPoint="0,0" EndPoint="1,1">
            <GradientStop Color="#F5F5F5" Offset="0"/>
            <GradientStop Color="#EEEEEE" Offset="0.5"/>
            <GradientStop Color="#E8E8E8" Offset="1"/>
        </LinearGradientBrush>
        
        <LinearGradientBrush x:Key="DarkMainGradient" StartPoint="0,0" EndPoint="1,1">
            <GradientStop Color="#1a1a1a" Offset="0"/>
            <GradientStop Color="#2d2d2d" Offset="1"/>
        </LinearGradientBrush>
        <LinearGradientBrush x:Key="DarkSecondaryGradient" StartPoint="0,0" EndPoint="1,1">
            <GradientStop Color="#2a2a2a" Offset="0"/>
            <GradientStop Color="#3a3a3a" Offset="1"/>
        </LinearGradientBrush>
        <LinearGradientBrush x:Key="DarkBackground" StartPoint="0,0" EndPoint="1,1">
            <GradientStop Color="#000000" Offset="0"/>
            <GradientStop Color="#0a0a0a" Offset="0.5"/>
            <GradientStop Color="#050505" Offset="1"/>
        </LinearGradientBrush>
        
        <Style x:Key="ToggleSwitch" TargetType="CheckBox">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <Grid>
                            <Border Name="BackgroundBorder" Width="60" Height="30" CornerRadius="15" Background="#3a3a3a">
                                <Border.Effect><DropShadowEffect ShadowDepth="2" Opacity="0.3" BlurRadius="5"/></Border.Effect>
                            </Border>
                            <Ellipse Name="ToggleCircle" Width="26" Height="26" Fill="White" HorizontalAlignment="Left" Margin="2,0,0,0">
                                <Ellipse.RenderTransform><TranslateTransform x:Name="ToggleTransform" X="0"/></Ellipse.RenderTransform>
                                <Ellipse.Effect><DropShadowEffect ShadowDepth="1" Opacity="0.3" BlurRadius="3"/></Ellipse.Effect>
                            </Ellipse>
                            <TextBlock Name="ThemeIcon" Text="☀️" FontSize="16" HorizontalAlignment="Left" VerticalAlignment="Center" Margin="7,0,0,0"/>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Trigger.EnterActions><BeginStoryboard>
                                    <Storyboard>
                                        <DoubleAnimation Storyboard.TargetName="ToggleTransform" Storyboard.TargetProperty="X" To="30" Duration="0:0:0.3">
                                            <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
                                        </DoubleAnimation>
                                        <ColorAnimation Storyboard.TargetName="BackgroundBorder" Storyboard.TargetProperty="Background.Color" To="#1a1a1a" Duration="0:0:0.3"/>
                                    </Storyboard>
                                </BeginStoryboard></Trigger.EnterActions>
                                <Setter TargetName="ThemeIcon" Property="Text" Value="🌙"/>
                                <Setter TargetName="ThemeIcon" Property="Margin" Value="33,0,0,0"/>
                                <Setter TargetName="ToggleCircle" Property="Fill" Value="#666666"/>
                            </Trigger>
                             <Trigger Property="IsChecked" Value="False">
                                <Trigger.EnterActions><BeginStoryboard>
                                    <Storyboard>
                                        <DoubleAnimation Storyboard.TargetName="ToggleTransform" Storyboard.TargetProperty="X" To="0" Duration="0:0:0.3">
                                            <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
                                        </DoubleAnimation>
                                        <ColorAnimation Storyboard.TargetName="BackgroundBorder" Storyboard.TargetProperty="Background.Color" To="#3a3a3a" Duration="0:0:0.3"/>
                                    </Storyboard>
                                </BeginStoryboard></Trigger.EnterActions>
                                <Setter TargetName="ThemeIcon" Property="Text" Value="☀️"/>
                                <Setter TargetName="ThemeIcon" Property="Margin" Value="7,0,0,0"/>
                                <Setter TargetName="ToggleCircle" Property="Fill" Value="White"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        
        <Style x:Key="ModernButton" TargetType="Button">
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="20,12"/>
            <Setter Property="Margin" Value="5"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Name="border" Background="{TemplateBinding Background}" CornerRadius="25" Padding="{TemplateBinding Padding}">
                            <Border.Effect><DropShadowEffect ShadowDepth="3" Opacity="0.3" BlurRadius="10"/></Border.Effect>
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="RenderTransform">
                                    <Setter.Value><ScaleTransform ScaleX="1.05" ScaleY="1.05" CenterX="50" CenterY="25"/></Setter.Value>
                                </Setter>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="RenderTransform">
                                    <Setter.Value><ScaleTransform ScaleX="0.95" ScaleY="0.95" CenterX="50" CenterY="25"/></Setter.Value>
                                </Setter>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="CardStyle" TargetType="Border">
            <Setter Property="Background" Value="#FAF7F2"/>
            <Setter Property="CornerRadius" Value="15"/>
            <Setter Property="Padding" Value="20"/>
            <Setter Property="Margin" Value="10"/>
            <Setter Property="Effect">
                <Setter.Value><DropShadowEffect ShadowDepth="5" Opacity="0.15" BlurRadius="20"/></Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>
    
    <Border Name="MainBorder" Background="{StaticResource LightBackground}" CornerRadius="0">
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="40"/>
                <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            
            <Border Name="TitleBar" Grid.Row="0" Background="#3a3a3a">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    
                    <TextBlock Grid.Column="0" Name="TitleText" Text="🔍 SISTEMA DE BUSCA AVANÇADA" Foreground="#F5F5F5" FontSize="14" FontWeight="Bold" VerticalAlignment="Center" Margin="15,0,0,0"/>
                    
                    <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,20,0">
                        <TextBlock Name="ThemeLabel" Text="Tema: " Foreground="#F5F5F5" VerticalAlignment="Center" Margin="0,0,10,0"/>
                        <CheckBox Name="ThemeToggle" Style="{StaticResource ToggleSwitch}"/>
                    </StackPanel>
                    
                    <StackPanel Grid.Column="3" Orientation="Horizontal" HorizontalAlignment="Right">
                        <Button Name="btnMinimize" Content="―" Width="45" Height="40" Background="Transparent" Foreground="#F5F5F5" BorderThickness="0" FontSize="16" Cursor="Hand"/>
                        <Button Name="btnMaximize" Content="▢" Width="45" Height="40" Background="Transparent" Foreground="#F5F5F5" BorderThickness="0" FontSize="16" Cursor="Hand"/>
                        <Button Name="btnClose" Content="✕" Width="45" Height="40" Background="#50FF0000" Foreground="White" BorderThickness="0" FontSize="16" Cursor="Hand"/>
                    </StackPanel>
                </Grid>
            </Border>
            
            <Grid Grid.Row="1" Margin="20">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                
                <Border Grid.Row="0" Name="SearchCard" Style="{StaticResource CardStyle}" Background="{StaticResource LightSolidDark}" Margin="0,0,0,20">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        
                        <TextBlock Grid.Row="0" Name="SearchTitle" Text="🔎 BUSCAR FICHAS DE INDISPONIBILIDADE" Foreground="#F5F5F5" FontSize="28" FontWeight="Bold" HorizontalAlignment="Center" Margin="0,0,0,20">
                            <TextBlock.Effect><DropShadowEffect ShadowDepth="2" Opacity="0.3"/></TextBlock.Effect>
                        </TextBlock>
                        
                        <Grid Grid.Row="1" Margin="0,0,0,15">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            
                            <Border Grid.Column="0" Name="SearchInputBorder" Background="#555555" CornerRadius="30" Margin="0,0,10,0">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="Auto"/>
                                        <ColumnDefinition Width="*"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock Grid.Column="0" Name="SearchIcon" Text="👤" FontSize="20" VerticalAlignment="Center" Margin="15,0,10,0" Foreground="#F5F5F5"/>
                                    <TextBox Grid.Column="1" Name="txtBusca" Background="Transparent" Foreground="#F5F5F5" BorderThickness="0" VerticalAlignment="Center" FontSize="18" Padding="10,8"/>
                                </Grid>
                            </Border>
                            
                            <Button Grid.Column="1" Name="btnPesquisar" Style="{StaticResource ModernButton}" Background="{StaticResource LightSolidDarkAlt}" Width="150">
                                <StackPanel Orientation="Horizontal">
                                    <TextBlock Text="🔍 " FontSize="18"/>
                                    <TextBlock Text="BUSCAR" VerticalAlignment="Center"/>
                                </StackPanel>
                            </Button>
                        </Grid>

                        <Grid Grid.Row="2" Margin="0,5,0,0">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>

                            <CheckBox Grid.Column="0" Name="chkBuscarIndicadorReal" VerticalAlignment="Center" Margin="0,0,15,0">
                                <CheckBox.Style>
                                    <Style TargetType="CheckBox">
                                        <Setter Property="Foreground" Value="#F5F5F5"/>
                                        <Setter Property="FontSize" Value="14"/>
                                        <Setter Property="Cursor" Value="Hand"/>
                                    </Style>
                                </CheckBox.Style>
                                <TextBlock>
                                    <Run Text="🏢 Buscar apenas em "/>
                                    <Run Text="INDICADOR REAL" FontWeight="Bold"/>
                                </TextBlock>
                            </CheckBox>

                            <TextBlock Grid.Column="1" Name="lblStatus" Text="Sistema pronto para busca..." Foreground="#F5F5F5" FontSize="14" HorizontalAlignment="Right" FontStyle="Italic" Opacity="0.9" VerticalAlignment="Center"/>
                        </Grid>

                        <Button Grid.Row="3" Name="btnAbrirPasta" Style="{StaticResource ModernButton}" Background="{StaticResource LightSolidDarkAlt}" Visibility="Collapsed" HorizontalAlignment="Center" Margin="0,10,0,0">
                            <StackPanel Orientation="Horizontal">
                                <TextBlock Text="📁 " FontSize="18"/>
                                <TextBlock Text="ABRIR PASTA" VerticalAlignment="Center"/>
                            </StackPanel>
                        </Button>
                    </Grid>
                </Border>
                
                <Grid Grid.Row="1">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="1*"/>
                        <ColumnDefinition Width="1*"/>
                    </Grid.ColumnDefinitions>
                    
                    <Border Grid.Column="0" Name="ResultsCard" Style="{StaticResource CardStyle}" Margin="0,0,10,0" Background="{StaticResource LightCreamBackground}">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                            </Grid.RowDefinitions>
                            
                            <Border Grid.Row="0" Name="ResultsHeader" Background="{StaticResource LightSolidDark}" CornerRadius="10" Margin="-10,-10,-10,10">
                                <TextBlock Name="ResultsHeaderText" Text="📋 RESULTADOS" Foreground="#F5F5F5" FontSize="18" FontWeight="Bold" Margin="15,10"/>
                            </Border>
                            
                            <ListBox Grid.Row="1" Name="lstResultados" Background="Transparent" BorderThickness="0" ScrollViewer.HorizontalScrollBarVisibility="Disabled" FontSize="14">
                                <ListBox.ItemContainerStyle>
                                    <Style TargetType="ListBoxItem">
                                        <Setter Property="Background" Value="#FFFFFF"/>
                                        <Setter Property="Foreground" Value="#333333"/>
                                        <Setter Property="Margin" Value="0,2"/>
                                        <Setter Property="Padding" Value="10,8"/>
                                        <Setter Property="BorderBrush" Value="#E0E0E0"/>
                                        <Setter Property="BorderThickness" Value="0,0,0,1"/>
                                        <Style.Triggers>
                                            <Trigger Property="IsMouseOver" Value="True">
                                                <Setter Property="Background" Value="#F0F0F0"/>
                                            </Trigger>
                                            <Trigger Property="IsSelected" Value="True">
                                                <Setter Property="Background" Value="#4a4a4a"/>
                                                <Setter Property="Foreground" Value="White"/>
                                            </Trigger>
                                        </Style.Triggers>
                                    </Style>
                                </ListBox.ItemContainerStyle>
                            </ListBox>
                        </Grid>
                    </Border>
                    
                    <Border Grid.Column="1" Name="PreviewCard" Style="{StaticResource CardStyle}" Margin="10,0,0,0" Background="{StaticResource LightCreamBackground}">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                            </Grid.RowDefinitions>
                            
                            <Border Grid.Row="0" Name="PreviewHeader" Background="{StaticResource LightSolidDark}" CornerRadius="10" Margin="-10,-10,-10,10">
                                <TextBlock Name="PreviewHeaderText" Text="👁 VISUALIZAÇÃO" Foreground="#F5F5F5" FontSize="18" FontWeight="Bold" Margin="15,10"/>
                            </Border>
                            
                            <ScrollViewer Grid.Row="1" Name="scrollPreview" HorizontalScrollBarVisibility="Auto" VerticalScrollBarVisibility="Auto">
                                <Grid>
                                    <Image Name="imgPreview" Stretch="Uniform" HorizontalAlignment="Center" VerticalAlignment="Center" Cursor="Hand"/>
                                    <TextBlock Name="lblNoPreview" Text="Selecione um arquivo para visualizar" FontSize="16" Foreground="#666666" FontStyle="Italic" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                    <ProgressBar Name="progressPreview" IsIndeterminate="True" Height="5" VerticalAlignment="Top" Visibility="Collapsed"/>
                                </Grid>
                            </ScrollViewer>
                        </Grid>
                    </Border>
                </Grid>
            </Grid>
            
            <Border Name="PopupOverlay" Grid.RowSpan="2" Background="#80000000" Visibility="Collapsed">
                <Border Name="PopupContent" Background="White" CornerRadius="20" Width="400" Height="200" HorizontalAlignment="Center" VerticalAlignment="Center">
                    <Border.RenderTransform><ScaleTransform x:Name="PopupScale" ScaleX="0" ScaleY="0" CenterX="200" CenterY="100"/></Border.RenderTransform>
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="*"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Name="PopupIcon" Text="✅" FontSize="50" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        <TextBlock Grid.Row="1" Name="PopupMessage" Text="Mensagem" FontSize="18" FontWeight="SemiBold" Foreground="Black" HorizontalAlignment="Center" Margin="0,5"/>
                        <Button Grid.Row="2" Name="PopupButton" Content="OK" Width="100" Height="35" Margin="0,10,0,20" HorizontalAlignment="Center" Background="{StaticResource LightSolidDark}" Foreground="White" FontWeight="Bold" BorderThickness="0" Cursor="Hand"/>
                    </Grid>
                </Border>
            </Border>
            
            <Border Name="loadingOverlay" Grid.RowSpan="2" Background="#80000000" Visibility="Collapsed">
                <Border Name="LoadingContent" Background="White" CornerRadius="20" Width="400" Height="200" HorizontalAlignment="Center" VerticalAlignment="Center">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>

                        <!-- Botão X para fechar (visível apenas quando concluído) -->
                        <Button Grid.Row="0" Name="btnCloseLoading" Content="✕" Width="30" Height="30"
                                HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,-10,-10,0"
                                Background="Transparent" Foreground="#666666" BorderThickness="0"
                                FontSize="20" Cursor="Hand" Visibility="Collapsed"/>

                        <TextBlock Grid.Row="1" Name="LoadingIcon" Text="⏳" FontSize="40" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        <TextBlock Grid.Row="2" Name="lblLoading" Text="Processando..." FontSize="16" Foreground="Black" HorizontalAlignment="Center" Margin="0,10"/>
                        <TextBlock Grid.Row="2" Name="lblFileCount" Text="" FontSize="14" Foreground="#666666" HorizontalAlignment="Center" Margin="0,35,0,0"/>
                        <ProgressBar Grid.Row="3" Name="progressLoading" IsIndeterminate="True" Height="5" Margin="30,10,30,20"/>
                    </Grid>
                </Border>
            </Border>
        </Grid>
    </Border>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

## ATRIBUIÇÃO DE CONTROLES (GARANTE QUE AS VARIÁVEIS EXISTEM)
$mainBorder = $window.FindName("MainBorder")
$titleBar = $window.FindName("TitleBar")
$titleText = $window.FindName("TitleText")
$themeLabel = $window.FindName("ThemeLabel")
$themeToggle = $window.FindName("ThemeToggle")
$txtBusca = $window.FindName("txtBusca")
$searchIcon = $window.FindName("SearchIcon")
$btnPesquisar = $window.FindName("btnPesquisar")
$btnAbrirPasta = $window.FindName("btnAbrirPasta")
$chkBuscarIndicadorReal = $window.FindName("chkBuscarIndicadorReal")
$lblStatus = $window.FindName("lblStatus")
$lstResultados = $window.FindName("lstResultados")
$imgPreview = $window.FindName("imgPreview")
$lblNoPreview = $window.FindName("lblNoPreview")
$progressPreview = $window.FindName("progressPreview")
$loadingOverlay = $window.FindName("loadingOverlay")
$loadingContent = $window.FindName("LoadingContent")
$lblLoading = $window.FindName("lblLoading")
$lblFileCount = $window.FindName("lblFileCount")
$progressLoading = $window.FindName("progressLoading")
$btnCloseLoading = $window.FindName("btnCloseLoading")
$loadingIcon = $window.FindName("LoadingIcon")
$scrollPreview = $window.FindName("scrollPreview")
$searchCard = $window.FindName("SearchCard")
$searchTitle = $window.FindName("SearchTitle")
$searchInputBorder = $window.FindName("SearchInputBorder")
$resultsCard = $window.FindName("ResultsCard")
$resultsHeader = $window.FindName("ResultsHeader")
$resultsHeaderText = $window.FindName("ResultsHeaderText")
$previewCard = $window.FindName("PreviewCard")
$previewHeader = $window.FindName("PreviewHeader")
$previewHeaderText = $window.FindName("PreviewHeaderText")
$popupOverlay = $window.FindName("PopupOverlay")
$popupContent = $window.FindName("PopupContent")
$popupIcon = $window.FindName("PopupIcon")
$popupMessage = $window.FindName("PopupMessage")
$popupButton = $window.FindName("PopupButton")
$popupScale = $window.FindName("PopupScale")
$btnMinimize = $window.FindName("btnMinimize")
$btnMaximize = $window.FindName("btnMaximize")
$btnClose = $window.FindName("btnClose")

# --- FUNÇÃO DE TEMA CORRIGIDA ---
function Toggle-Theme {
    param([bool]$IsDark)

    # Write-Host "Toggle-Theme chamado com IsDark=$IsDark"

    try { # Adicionado Try/Catch para depuração
        # 1. Definição de Cores (Método Direto e Robusto)
        $brush_White = [System.Windows.Media.Brushes]::White
        $brush_Black = [System.Windows.Media.Brushes]::Black
        $brush_F5F5F5 = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#F5F5F5"))
        $brush_CCCCCC = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#CCCCCC"))
        $brush_AAAAAA = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#AAAAAA"))
        $brush_DDDDDD = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#DDDDDD"))
        $brush_666666 = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#666666"))
        $brush_333333 = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#333333"))
        $brush_F0F0F0 = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#F0F0F0"))

        $brush_1a1a1a = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#1a1a1a"))
        $brush_2a2a2a = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#2a2a2a"))
        $brush_3a3a3a = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#3a3a3a"))
        $brush_4a4a4a = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#4a4a4a"))
        $brush_555555 = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#555555"))

        $brush_TransWhite = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#10FFFFFF"))
        $brush_TransRed = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#50FF0000"))
        $brush_TransRedDark = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#50CC0000"))
        $brush_TransGray = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#20888888"))

        if ($IsDark) {
            $script:TemaAtual = "Dark"
            $mainBorder.Background = $window.FindResource("DarkBackground")
            $titleBar.Background = $brush_TransWhite
            $titleText.Foreground = $brush_CCCCCC
            $themeLabel.Foreground = $brush_CCCCCC
            $btnMinimize.Foreground = $brush_CCCCCC
            $btnMaximize.Foreground = $brush_CCCCCC
            $btnClose.Background = $brush_TransRedDark
            $btnClose.Foreground = $brush_CCCCCC
            $searchCard.Background = $window.FindResource("DarkMainGradient")
            $searchTitle.Foreground = $brush_CCCCCC
            $searchInputBorder.Background = $brush_TransGray
            $searchIcon.Foreground = $brush_AAAAAA
            $txtBusca.Foreground = $brush_DDDDDD
            $lblStatus.Foreground = $brush_AAAAAA
            $btnPesquisar.Background = $window.FindResource("DarkSecondaryGradient")
            $btnPesquisar.Foreground = $brush_CCCCCC
            $btnAbrirPasta.Background = $window.FindResource("DarkSecondaryGradient")
            $btnAbrirPasta.Foreground = $brush_CCCCCC
            $resultsCard.Background = $brush_1a1a1a
            $resultsHeader.Background = $window.FindResource("DarkSecondaryGradient")
            $resultsHeaderText.Foreground = $brush_CCCCCC
            $previewCard.Background = $brush_1a1a1a
            $previewHeader.Background = $window.FindResource("DarkSecondaryGradient")
            $previewHeaderText.Foreground = $brush_CCCCCC
            $lblNoPreview.Foreground = $brush_666666
            $popupContent.Background = $brush_2a2a2a
            $popupMessage.Foreground = $brush_CCCCCC
            $popupButton.Background = $window.FindResource("DarkSecondaryGradient")
            $loadingContent.Background = $brush_2a2a2a
            $lblLoading.Foreground = $brush_CCCCCC

            # --- Estilo da Lista (Dark) ---
            $lstResultados.Resources.Clear()
            $newStyle = New-Object System.Windows.Style([System.Windows.Controls.ListBoxItem])
            $newStyle.Setters.Add((New-Object System.Windows.Setter([System.Windows.Controls.Control]::BackgroundProperty, $brush_2a2a2a)))
            $newStyle.Setters.Add((New-Object System.Windows.Setter([System.Windows.Controls.Control]::ForegroundProperty, $brush_CCCCCC)))
            $hoverTrigger = New-Object System.Windows.Trigger
            $hoverTrigger.Property = [System.Windows.Controls.ListBoxItem]::IsMouseOverProperty
            $hoverTrigger.Value = $true
            $hoverTrigger.Setters.Add((New-Object System.Windows.Setter([System.Windows.Controls.Control]::BackgroundProperty, $brush_3a3a3a)))
            $newStyle.Triggers.Add($hoverTrigger)
            $selectedTrigger = New-Object System.Windows.Trigger
            $selectedTrigger.Property = [System.Windows.Controls.ListBoxItem]::IsSelectedProperty
            $selectedTrigger.Value = $true
            $selectedTrigger.Setters.Add((New-Object System.Windows.Setter([System.Windows.Controls.Control]::BackgroundProperty, $brush_4a4a4a)))
            $selectedTrigger.Setters.Add((New-Object System.Windows.Setter([System.Windows.Controls.Control]::ForegroundProperty, $brush_White)))
            $newStyle.Triggers.Add($selectedTrigger)
            $lstResultados.ItemContainerStyle = $newStyle
        } else {
            $script:TemaAtual = "Light"
            $mainBorder.Background = $window.FindResource("LightBackground")
            $titleBar.Background = $window.FindResource("LightSolidDark")
            $titleText.Foreground = $brush_F5F5F5
            $themeLabel.Foreground = $brush_F5F5F5
            $btnMinimize.Foreground = $brush_F5F5F5
            $btnMaximize.Foreground = $brush_F5F5F5
            $btnClose.Background = $brush_TransRed
            $btnClose.Foreground = $brush_White
            $searchCard.Background = $window.FindResource("LightSolidDark")
            $searchTitle.Foreground = $brush_F5F5F5
            $searchInputBorder.Background = $brush_555555
            $searchIcon.Foreground = $brush_F5F5F5
            $txtBusca.Foreground = $brush_F5F5F5
            $lblStatus.Foreground = $brush_F5F5F5
            $btnPesquisar.Background = $window.FindResource("LightSolidDarkAlt")
            $btnPesquisar.Foreground = $brush_F5F5F5
            $btnAbrirPasta.Background = $window.FindResource("LightSolidDarkAlt")
            $btnAbrirPasta.Foreground = $brush_F5F5F5
            $resultsCard.Background = $window.FindResource("LightCreamBackground")
            $resultsHeader.Background = $window.FindResource("LightSolidDark")
            $resultsHeaderText.Foreground = $brush_F5F5F5
            $previewCard.Background = $window.FindResource("LightCreamBackground")
            $previewHeader.Background = $window.FindResource("LightSolidDark")
            $previewHeaderText.Foreground = $brush_F5F5F5
            $lblNoPreview.Foreground = $brush_666666
            $popupContent.Background = $brush_White
            $popupMessage.Foreground = $brush_Black
            $popupButton.Background = $window.FindResource("LightSolidDark")
            $loadingContent.Background = $brush_White
            $lblLoading.Foreground = $brush_Black

            # --- Estilo da Lista (Light) ---
            $lstResultados.Resources.Clear()
            $newStyle = New-Object System.Windows.Style([System.Windows.Controls.ListBoxItem])
            $newStyle.Setters.Add((New-Object System.Windows.Setter([System.Windows.Controls.Control]::BackgroundProperty, $brush_White)))
            $newStyle.Setters.Add((New-Object System.Windows.Setter([System.Windows.Controls.Control]::ForegroundProperty, $brush_333333)))
            $hoverTrigger = New-Object System.Windows.Trigger
            $hoverTrigger.Property = [System.Windows.Controls.ListBoxItem]::IsMouseOverProperty
            $hoverTrigger.Value = $true
            $hoverTrigger.Setters.Add((New-Object System.Windows.Setter([System.Windows.Controls.Control]::BackgroundProperty, $brush_F0F0F0)))
            $newStyle.Triggers.Add($hoverTrigger)
            $selectedTrigger = New-Object System.Windows.Trigger
            $selectedTrigger.Property = [System.Windows.Controls.ListBoxItem]::IsSelectedProperty
            $selectedTrigger.Value = $true
            $selectedTrigger.Setters.Add((New-Object System.Windows.Setter([System.Windows.Controls.Control]::BackgroundProperty, $brush_4a4a4a)))
            $selectedTrigger.Setters.Add((New-Object System.Windows.Setter([System.Windows.Controls.Control]::ForegroundProperty, $brush_White)))
            $newStyle.Triggers.Add($selectedTrigger)
            $lstResultados.ItemContainerStyle = $newStyle
        }

        # Write-Host "Toggle-Theme aplicado com sucesso: $(if($IsDark){'Dark'}else{'Light'})"
    }
    catch {
        # Se qualquer linha acima falhar, loga o erro mas não mostra popup durante inicialização
        # Write-Warning "Erro ao trocar tema: $($_.Exception.Message)"
        # Write-Warning "StackTrace: $($_.ScriptStackTrace)"
    }
}
# --- FIM DA FUNÇÃO DE TEMA ---

# --- FUNÇÃO SHOW-POPUP CORRIGIDA ---
function Show-Popup {
    param([string]$Icon, [string]$Message, [string]$Type = "Success")

    $popupIcon.Text = $Icon
    $popupMessage.Text = $Message

    if ($script:TemaAtual -eq "Dark") {
        $popupContent.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#2a2a2a"))
        $popupMessage.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#CCCCCC"))
        $popupButton.Background = $window.FindResource("DarkSecondaryGradient")
    } else {
        $popupContent.Background = [System.Windows.Media.Brushes]::White
        $popupMessage.Foreground = [System.Windows.Media.Brushes]::Black
        $popupButton.Background = $window.FindResource("LightSolidDark")
    }

    switch ($Type) {
        "Success" { $popupIcon.Foreground = [System.Windows.Media.Brushes]::Green }
        "Error" { $popupIcon.Foreground = [System.Windows.Media.Brushes]::Red }
        "Warning" { $popupIcon.Foreground = [System.Windows.Media.Brushes]::Orange }
        "Info" { $popupIcon.Foreground = [System.Windows.Media.Brushes]::Blue }
    }

    $popupOverlay.Visibility = 'Visible'
    $storyboard = New-Object System.Windows.Media.Animation.Storyboard
    $scaleXAnimation = New-Object System.Windows.Media.Animation.DoubleAnimation
    $scaleXAnimation.From = 0; $scaleXAnimation.To = 1
    $scaleXAnimation.Duration = [System.Windows.Duration]::new([System.TimeSpan]::FromMilliseconds(300))
    $scaleXAnimation.EasingFunction = New-Object System.Windows.Media.Animation.BackEase
    $scaleXAnimation.EasingFunction.EasingMode = 'EaseOut'
    $scaleYAnimation = New-Object System.Windows.Media.Animation.DoubleAnimation
    $scaleYAnimation.From = 0; $scaleYAnimation.To = 1
    $scaleYAnimation.Duration = [System.Windows.Duration]::new([System.TimeSpan]::FromMilliseconds(300))
    $scaleYAnimation.EasingFunction = New-Object System.Windows.Media.Animation.BackEase
    $scaleYAnimation.EasingFunction.EasingMode = 'EaseOut'

    [System.Windows.Media.Animation.Storyboard]::SetTarget($scaleXAnimation, $popupScale)
    [System.Windows.Media.Animation.Storyboard]::SetTargetProperty($scaleXAnimation, 'ScaleX')
    [System.Windows.Media.Animation.Storyboard]::SetTarget($scaleYAnimation, $popupScale)
    [System.Windows.Media.Animation.Storyboard]::SetTargetProperty($scaleYAnimation, 'ScaleY')

    $storyboard.Children.Add($scaleXAnimation)
    $storyboard.Children.Add($scaleYAnimation)
    $storyboard.Begin()

    # Timer para fechar automaticamente após 3 segundos
    $autoCloseTimer = New-Object System.Windows.Threading.DispatcherTimer
    $autoCloseTimer.Interval = [TimeSpan]::FromSeconds(3)
    $autoCloseTimer.Add_Tick({
        # Write-Host "Timer de auto-close disparado - fechando popup automaticamente"
        Hide-Popup
        $autoCloseTimer.Stop()
    })
    $autoCloseTimer.Start()
}
# --- FIM DA FUNÇÃO SHOW-POPUP ---

function Hide-Popup {
    # Write-Host "Hide-Popup chamado"

    # Esconder overlay imediatamente (sem animação para garantir que funciona)
    $popupOverlay.Visibility = 'Collapsed'
    # Write-Host "Overlay escondido"
}


# Event Handlers

$themeToggle.Add_Checked({
    try {
        Toggle-Theme -IsDark $true
    }
    catch {
        # Write-Warning "Erro ao ativar tema escuro: $($_.Exception.Message)"
    }
})
$themeToggle.Add_Unchecked({
    try {
        Toggle-Theme -IsDark $false
    }
    catch {
        # Write-Warning "Erro ao desativar tema escuro: $($_.Exception.Message)"
    }
})
$popupButton.Add_Click({
    # Write-Host "Botão popup clicado"
    Hide-Popup
})

# Permitir fechar o loading clicando no botão X
$btnCloseLoading.Add_Click({
    # Write-Host "Botão X do loading clicado"
    if ($btnCloseLoading.Visibility -eq 'Visible') {
        $loadingOverlay.Visibility = 'Collapsed'
    }
})

# Permitir fechar o loading clicando no overlay escuro (apenas quando concluído)
$loadingOverlay.Add_MouseLeftButtonDown({
    param($sender, $e)
    # Verifica se o clique foi no overlay (fundo escuro) e não no conteúdo
    # E só permite fechar se o botão X estiver visível (ou seja, busca concluída)
    if ($e.Source -eq $loadingOverlay -and $btnCloseLoading.Visibility -eq 'Visible') {
        # Write-Host "Overlay do loading clicado - fechando"
        $loadingOverlay.Visibility = 'Collapsed'
    }
})

# Permitir fechar o popup clicando no overlay escuro
$popupOverlay.Add_MouseLeftButtonDown({
    param($sender, $e)
    # Verifica se o clique foi no overlay (fundo escuro) e não no conteúdo do popup
    if ($e.Source -eq $popupOverlay) {
        # Write-Host "Overlay clicado - fechando popup"
        Hide-Popup
    }
})

# Permitir fechar o popup com ESC
$window.Add_KeyDown({
    param($sender, $e)
    if ($e.Key -eq 'Escape' -and $popupOverlay.Visibility -eq 'Visible') {
        # Write-Host "ESC pressionado - fechando popup"
        Hide-Popup
    }
})

$titleBar.Add_MouseLeftButtonDown({ $window.DragMove() })
$btnMinimize.Add_Click({ $window.WindowState = 'Minimized' })
$btnMaximize.Add_Click({
    if ($window.WindowState -eq 'Maximized') {
        $window.WindowState = 'Normal'
        $btnMaximize.Content = "▢"
    } else {
        $window.WindowState = 'Maximized'
        $btnMaximize.Content = "◱"
    }
})

$btnClose.Add_Click({
    if ($script:PastaTemporaria) {
        Remove-PastaTemporaria -Caminho $script:PastaTemporaria
    }
    if ($script:timer -and $script:timer.IsEnabled) {
        $script:timer.Stop()
    }
    # Cleanup de runspaces se estiver em execução
    if ($script:runspaceData) {
        foreach ($rs in $script:runspaceData.Runspaces) {
            if ($rs.Pipe) {
                $rs.Pipe.Stop()
                $rs.Pipe.Dispose()
            }
        }
        if ($script:runspaceData.Pool) {
            $script:runspaceData.Pool.Close()
            $script:runspaceData.Pool.Dispose()
        }
        $script:runspaceData = $null
    }
    $window.Close()
})

$txtBusca.Add_KeyDown({
    param($sender, $e)
    if ($e.Key -eq 'Return') {
        $btnPesquisar.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    }
})

# --- BLOCO DE BUSCA (Runspaces Paralelos) ---
$btnPesquisar.Add_Click({
    if ($script:BuscaEmAndamento) {
        $lblStatus.Text = "⚠️ Aguarde... busca em andamento."
        return
    }

    $nomeDigitado = $txtBusca.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($nomeDigitado)) {
        $lblStatus.Text = "⚠️ Digite um nome para buscar."
        return
    }
    
    # --- Limpeza e Preparação ---
    $loadingOverlay.Visibility = 'Visible'
    $lblLoading.Text = "Iniciando busca em segundo plano..."
    $lblStatus.Text = "Buscando arquivos na rede..."
    
    $btnAbrirPasta.Visibility = 'Collapsed'
    $lstResultados.Items.Clear()
    $imgPreview.Source = $null
    $lblNoPreview.Visibility = 'Visible'
    $script:ArquivosEncontrados = @()
    
    if ($script:PastaTemporaria) {
        Remove-PastaTemporaria -Caminho $script:PastaTemporaria
    }
    $script:PastaTemporaria = New-PastaTemporaria
    if (-not $script:PastaTemporaria) {
        $loadingOverlay.Visibility = 'Collapsed'
        $lblStatus.Text = "❌ Erro crítico: Não foi possível criar pasta temporária"
        # Write-Warning "Erro crítico: Não foi possível criar pasta temporária"
        return
    }
    
    $script:BuscaEmAndamento = $true

    # Verificar se deve buscar apenas em INDICADOR REAL ou excluir essa pasta
    $buscarApenasIndicadorReal = $chkBuscarIndicadorReal.IsChecked -eq $true
    $pastaIndicadorReal = "\\192.168.20.100\TRABALHO\TRANSITO\FICHAS INDISPONIBILIDADE NOVAS RENOMEADAS\INDICADOR REAL"

    # Detectar tipo de busca e preparar padrão
    $isBuscaDocumento = Test-IsDocumento -Texto $nomeDigitado
    if ($isBuscaDocumento) {
        $nomeBusca = Format-NumeroDocumento -Texto $nomeDigitado
        # Write-Host "══════════════════════════════════════════════════════"
        # Write-Host "TIPO DE BUSCA: CPF/CNPJ"
        # Write-Host "Padrão de busca: $nomeBusca"
    } else {
        $nomeBusca = Format-NomeBusca -NomeDigitado $nomeDigitado
        if ($buscarApenasIndicadorReal) {
            # Write-Host "══════════════════════════════════════════════════════"
            # Write-Host "TIPO DE BUSCA: RUA/LOTEAMENTO (apenas INDICADOR REAL)"
            # Write-Host "Padrão de busca: $nomeBusca"
        } else {
            # Write-Host "══════════════════════════════════════════════════════"
            # Write-Host "TIPO DE BUSCA: NOME DE PESSOA"
            # Write-Host "Padrão de busca: $nomeBusca"
        }
    }

    if ($buscarApenasIndicadorReal) {
        # Buscar APENAS na pasta INDICADOR REAL (ruas/loteamentos)
        $caminhoParaBusca = $pastaIndicadorReal
        $pastaParaIgnorar = ""
        # Write-Host "Local: APENAS pasta INDICADOR REAL"
    } else {
        # Buscar em todas EXCETO INDICADOR REAL (nomes/CPF/CNPJ)
        $caminhoParaBusca = $script:CaminhoBase
        $pastaParaIgnorar = $pastaIndicadorReal
        # Write-Host "Local: TODAS as pastas EXCETO INDICADOR REAL"
    }
    # Write-Host "══════════════════════════════════════════════════════"

    $logFilePath = Join-Path $script:PastaTemporaria "busca_log.txt"
    $script:FileCountFile = Join-Path $script:PastaTemporaria "file_count.txt"

    # Inicializar arquivo de contagem
    try {
        "0" | Out-File -FilePath $script:FileCountFile -Force -ErrorAction Stop
        # Write-Host "Arquivo de contagem criado: $script:FileCountFile"
    } catch {
        # Write-Warning "Erro ao criar arquivo de contagem: $_"
    }

    # Resetar o loading para estado de processamento
    $lblLoading.Text = "Processando..."
    $lblFileCount.Text = "Encontrando... 0 arquivos"
    $progressLoading.IsIndeterminate = $true
    $progressLoading.Visibility = 'Visible'
    $btnCloseLoading.Visibility = 'Collapsed'
    $loadingIcon.Text = "⏳"

    # --- Script da Busca PARALELA (ScriptBlock para Runspaces) ---
    $scriptBlock = {
        param($PastasParaBuscar, $PadraoNome, $PastaIgnorar, $CountFilePath, $IsBuscaDocumento, $ThreadID)

        # --- Funções auxiliares (devem ser redefinidas dentro do runspace) ---
        function Remove-Acentos-Local {
            param([string]$Texto)
            $comAcentos = "ÀÁÂÃÄÅàáâãäåÈÉÊËèéêëÌÍÎÏìíîïÒÓÔÕÖòóôõöÙÚÛÜùúûüÝýÿÑñÇç"
            $semAcentos = "AAAAAAaaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuYyyNnCc"
            $resultado = $Texto
            for ($i = 0; $i -lt $comAcentos.Length; $i++) {
                $resultado = $resultado.Replace($comAcentos[$i], $semAcentos[$i])
            }
            return $resultado
        }

        function Remove-Separadores {
            param([string]$Texto)
            return $Texto -replace '[_\s\-]', ''
        }
        # --- Fim das funções auxiliares ---

        $arquivosEncontrados = [System.Collections.Generic.List[string]]::new()
        $pastasParaIgnorar = $PastaIgnorar.TrimEnd('\').ToUpper()

        # Pré-calcular padrão sem separadores
        $padraoSemSeparadores = ""
        if (-not $IsBuscaDocumento) {
            $padraoSemSeparadores = Remove-Separadores -Texto $PadraoNome
        }

        function Search-FilesNet {
            param([string]$Pasta)

            $pastaNormalizada = $Pasta.TrimEnd('\').ToUpper()

            # Só ignora pasta se $pastasParaIgnorar não estiver vazio
            if (-not [string]::IsNullOrWhiteSpace($pastasParaIgnorar) -and $pastaNormalizada.Contains($pastasParaIgnorar)) {
                return
            }

            try {
                $files = [System.IO.Directory]::EnumerateFiles($Pasta, "*.pdf", [System.IO.SearchOption]::TopDirectoryOnly)
                foreach ($arquivo in $files) {
                    $nomeArquivo = [System.IO.Path]::GetFileName($arquivo)
                    $nomeArquivoNormalizado = (Remove-Acentos-Local -Texto $nomeArquivo).ToUpper()

                    $matchEncontrado = $false

                    if ($IsBuscaDocumento) {
                        # Busca por documento (CPF/CNPJ)
                        if ($nomeArquivo -match "-$PadraoNome\.pdf$") {
                            $matchEncontrado = $true
                        }
                    } else {
                        # Busca por nome ou rua
                        $nomeArquivoSemSeparadores = Remove-Separadores -Texto $nomeArquivoNormalizado
                        if ($nomeArquivoSemSeparadores.Contains($padraoSemSeparadores)) {
                            $matchEncontrado = $true
                        }
                    }

                    if ($matchEncontrado) {
                        $arquivosEncontrados.Add($arquivo)

                        # Atualizar contagem em arquivo específico para este thread
                        try {
                            $threadCountFile = "$CountFilePath.$ThreadID"
                            $arquivosEncontrados.Count.ToString() | Out-File -FilePath $threadCountFile -Force -NoNewline
                        } catch {}
                    }
                }

                $subpastas = [System.IO.Directory]::EnumerateDirectories($Pasta, "*", [System.IO.SearchOption]::TopDirectoryOnly)
                foreach ($subpasta in $subpastas) {
                    Search-FilesNet -Pasta $subpasta
                }
            }
            catch {
                # Ignora erros de acesso
            }
        }

        # Buscar em todas as pastas atribuídas a este thread
        foreach ($pasta in $PastasParaBuscar) {
            if (Test-Path $pasta) {
                Search-FilesNet -Pasta $pasta
            }
        }

        return $arquivosEncontrados.ToArray()
    } # --- Fim do ScriptBlock ---

    # 1. Enumerar pastas de primeiro e segundo nível para distribuir entre threads
    $todasPastas = @()
    try {
        if ($buscarApenasIndicadorReal) {
            # Se buscar apenas INDICADOR REAL, usar ela diretamente e suas subpastas
            $todasPastas = @($pastaIndicadorReal)
            try {
                $subpastasIndicador = [System.IO.Directory]::EnumerateDirectories($pastaIndicadorReal)
                $todasPastas += $subpastasIndicador
            } catch {}
        } else {
            # Enumerar subpastas do caminho base (primeiro nível)
            $pastasNivel1 = [System.IO.Directory]::EnumerateDirectories($caminhoParaBusca) | Where-Object {
                if ($pastaParaIgnorar) {
                    $_.ToUpper() -notlike "$($pastaParaIgnorar.ToUpper())*"
                } else {
                    $true
                }
            }

            # Adicionar pastas de primeiro nível
            $todasPastas += $pastasNivel1

            # Para cada pasta de primeiro nível, adicionar também suas subpastas (segundo nível)
            foreach ($pasta in $pastasNivel1) {
                try {
                    $subpastas = [System.IO.Directory]::EnumerateDirectories($pasta) | Where-Object {
                        if ($pastaParaIgnorar) {
                            $_.ToUpper() -notlike "$($pastaParaIgnorar.ToUpper())*"
                        } else {
                            $true
                        }
                    }
                    $todasPastas += $subpastas
                } catch {
                    # Ignora erros de acesso a subpastas
                }
            }
        }
    } catch {
        $lblStatus.Text = "❌ Erro ao enumerar pastas"
        $loadingOverlay.Visibility = 'Collapsed'
        $script:BuscaEmAndamento = $false
        return
    }

    if ($todasPastas.Count -eq 0) {
        $lblStatus.Text = "⚠️ Nenhuma pasta encontrada para buscar"
        $loadingOverlay.Visibility = 'Collapsed'
        $script:BuscaEmAndamento = $false
        return
    }

    # 2. Determinar número de threads (sempre usa 10, a menos que haja menos pastas)
    $numThreads = [Math]::Min(10, [Math]::Max(2, $todasPastas.Count))

    # 3. Criar RunspacePool
    $runspacePool = [runspacefactory]::CreateRunspacePool(1, $numThreads)
    $runspacePool.Open()

    # 4. Dividir pastas entre threads
    $pastasPorThread = [Math]::Ceiling($todasPastas.Count / $numThreads)
    $runspaces = @()

    for ($i = 0; $i -lt $numThreads; $i++) {
        $inicio = $i * $pastasPorThread
        $fim = [Math]::Min($inicio + $pastasPorThread, $todasPastas.Count)

        if ($inicio -ge $todasPastas.Count) { break }

        $pastasThread = $todasPastas[$inicio..($fim-1)]

        # Inicializar arquivo de contagem para este thread
        $threadCountFile = "$($script:FileCountFile).$i"
        "0" | Out-File -FilePath $threadCountFile -Force -NoNewline -ErrorAction SilentlyContinue

        $powershell = [powershell]::Create()
        $powershell.RunspacePool = $runspacePool
        [void]$powershell.AddScript($scriptBlock)
        [void]$powershell.AddArgument($pastasThread)
        [void]$powershell.AddArgument($nomeBusca)
        [void]$powershell.AddArgument($pastaParaIgnorar)
        [void]$powershell.AddArgument($script:FileCountFile)
        [void]$powershell.AddArgument($isBuscaDocumento)
        [void]$powershell.AddArgument($i)

        $runspaces += @{
            Pipe = $powershell
            Status = $powershell.BeginInvoke()
        }
    }

    $script:runspaceData = @{
        Pool = $runspacePool
        Runspaces = $runspaces
        StartTime = Get-Date
        NumThreads = $numThreads
    }

    # 5. Para o timer antigo, se existir
    if ($script:timer -and $script:timer.IsEnabled) {
        $script:timer.Stop()
    }

    # 6. Cria timer para verificar progresso dos runspaces
    $script:timer = New-Object System.Windows.Threading.DispatcherTimer
    $script:timer.Interval = [TimeSpan]::FromMilliseconds(250)

    $script:timer.Add_Tick({
        if (-not $script:runspaceData) {
            $script:timer.Stop()
            return
        }

        $allComplete = $true
        foreach ($rs in $script:runspaceData.Runspaces) {
            if (-not $rs.Status.IsCompleted) {
                $allComplete = $false
                break
            }
        }

        # Atualizar tempo decorrido e contagem em tempo real
        $elapsed = (Get-Date) - $script:runspaceData.StartTime

        # Ler contagens de todos os threads
        $totalCount = 0
        $numThreadsAtual = $script:runspaceData.NumThreads
        for ($i = 0; $i -lt $numThreadsAtual; $i++) {
            $threadCountFile = "$($script:FileCountFile).$i"
            if (Test-Path $threadCountFile) {
                try {
                    $count = Get-Content $threadCountFile -Raw -ErrorAction SilentlyContinue
                    if ($count -and $count.Trim()) {
                        $totalCount += [int]$count.Trim()
                    }
                } catch {}
            }
        }

        $lblFileCount.Text = "Buscando... $totalCount arquivos ($($elapsed.ToString('mm\:ss'))s | $numThreadsAtual threads)"

        if ($allComplete) {
            # TODOS OS THREADS TERMINARAM!
            $script:timer.Stop()

            # Coletar resultados de todos os runspaces
            $todosResultados = [System.Collections.Generic.List[string]]::new()

            foreach ($rs in $script:runspaceData.Runspaces) {
                try {
                    $resultado = $rs.Pipe.EndInvoke($rs.Status)
                    if ($resultado) {
                        foreach ($arquivo in $resultado) {
                            $todosResultados.Add($arquivo)
                        }
                    }
                } catch {
                    # Ignora erros individuais
                }
                $rs.Pipe.Dispose()
            }

            # Cleanup
            $script:runspaceData.Pool.Close()
            $script:runspaceData.Pool.Dispose()
            $script:runspaceData = $null

            # Atribuir resultados
            $script:ArquivosEncontrados = $todosResultados.ToArray()

            # Exibir resultados na UI
            if ($script:ArquivosEncontrados.Count -gt 0) {
                # SUCESSO
                foreach ($arquivo in $script:ArquivosEncontrados) {
                    $nome = [System.IO.Path]::GetFileName($arquivo)
                    $lstResultados.Items.Add("📄 $nome")
                }
                $lblStatus.Text = "✅ $($script:ArquivosEncontrados.Count) arquivo(s) encontrado(s) em $($elapsed.ToString('mm\:ss'))s"
                $btnAbrirPasta.Visibility = 'Visible'

                $loadingIcon.Text = "✅"
                $lblLoading.Text = "Pesquisa concluída!"
                $lblFileCount.Text = "$($script:ArquivosEncontrados.Count) arquivos encontrados"
                $progressLoading.IsIndeterminate = $false
                $progressLoading.Value = 100
                $btnCloseLoading.Visibility = 'Visible'
            } else {
                # NENHUM RESULTADO
                $lstResultados.Items.Add("❌ Nenhum arquivo encontrado")
                $lblStatus.Text = "⚠️ Nenhum arquivo encontrado"

                $loadingIcon.Text = "❌"
                $lblLoading.Text = "Pesquisa concluída"
                $lblFileCount.Text = "Nenhum arquivo encontrado"
                $progressLoading.Visibility = 'Collapsed'
                $btnCloseLoading.Visibility = 'Visible'
            }

            $script:BuscaEmAndamento = $false
        }
    })

    # 7. Inicia o timer
    $script:timer.Start()
})
# --- FIM DO BLOCO DE BUSCA ---


# Seleção na lista (Preview)
$lstResultados.Add_SelectionChanged({
    try {
        $selectedIndex = $lstResultados.SelectedIndex

        if ($selectedIndex -ge 0 -and $selectedIndex -lt $script:ArquivosEncontrados.Count) {
            # Limpar imagem anterior ANTES de gerar nova (crítico!)
            if ($imgPreview.Source) {
                $imgPreview.Source = $null
                # Forçar invalidação visual do controle
                $imgPreview.InvalidateVisual()
                $imgPreview.UpdateLayout()
                [System.GC]::Collect()
                [System.GC]::WaitForPendingFinalizers()
            }

            $progressPreview.Visibility = 'Visible'
            $lblNoPreview.Visibility = 'Collapsed'
            $lblStatus.Text = "Gerando pré-visualização..."

            $originalFile = $script:ArquivosEncontrados[$selectedIndex]
            $fileName = [System.IO.Path]::GetFileName($originalFile)
            $localFile = Join-Path $script:PastaTemporaria $fileName

            if (-not (Test-Path $localFile)) {
                try {
                    Copy-Item -Path $originalFile -Destination $localFile -Force -ErrorAction Stop
                } catch {
                    $progressPreview.Visibility = 'Collapsed'
                    $lblNoPreview.Text = "❌ Erro ao copiar o arquivo para preview."
                    $lblNoPreview.Visibility = 'Visible'
                    $lblStatus.Text = "❌ Falha ao copiar arquivo para preview."
                    # Write-Warning "Erro ao copiar arquivo: $_"
                    return
                }
            }

            $previewPath = Generate-PdfPreviewImage -PdfPath $localFile

            $progressPreview.Visibility = 'Collapsed'

            if ($previewPath -and (Test-Path $previewPath)) {
                try {
                    # SOLUÇÃO DEFINITIVA: Carregar da MEMÓRIA para evitar qualquer cache
                    # Ler arquivo em bytes
                    $imageBytes = [System.IO.File]::ReadAllBytes($previewPath)

                    # Criar MemoryStream com os bytes
                    $memoryStream = New-Object System.IO.MemoryStream
                    $memoryStream.Write($imageBytes, 0, $imageBytes.Length)
                    $memoryStream.Position = 0

                    # Criar bitmap a partir do MemoryStream
                    $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
                    $bitmap.BeginInit()
                    $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
                    $bitmap.StreamSource = $memoryStream
                    $bitmap.EndInit()
                    $bitmap.Freeze()

                    # Fechar stream DEPOIS de freeze
                    $memoryStream.Close()
                    $memoryStream.Dispose()

                    $imgPreview.Source = $bitmap

                    # Forçar renderização da nova imagem
                    $imgPreview.InvalidateVisual()
                    $imgPreview.UpdateLayout()

                    $lblNoPreview.Visibility = 'Collapsed'
                    $lblStatus.Text = "🔍 Visualização ajustada (Clique para Zoom 1:1)"
                    # Write-Host "Preview carregado da memória: $previewPath (tamanho: $($imageBytes.Length) bytes)"
                } catch {
                    $lblNoPreview.Text = "❌ Erro ao carregar imagem: $($_.Exception.Message)"
                    $lblNoPreview.Visibility = 'Visible'
                    $lblStatus.Text = "❌ Falha ao carregar preview."
                    # Write-Warning "Erro ao criar bitmap: $_"
                    # Write-Warning "Preview path: $previewPath"
                }
            } else {
                if (-not $previewPath) {
                    $lblNoPreview.Text = "❌ Ghostscript falhou ao gerar preview. Verifique se está instalado em:`n$($script:GhostscriptExePath)"
                } else {
                    $lblNoPreview.Text = "❌ Arquivo de preview não encontrado: $previewPath"
                }
                $lblNoPreview.Visibility = 'Visible'
                $lblStatus.Text = "❌ Falha ao gerar preview."
                # Write-Warning "Preview falhou. Path retornado: $previewPath"
            }
        }
    } catch {
        $progressPreview.Visibility = 'Collapsed'
        $lblNoPreview.Text = "❌ Erro inesperado ao gerar preview."
        $lblNoPreview.Visibility = 'Visible'
        $lblStatus.Text = "❌ Erro ao processar seleção."
        # Write-Warning "Erro no evento SelectionChanged: $_"
        # Write-Warning $_.ScriptStackTrace
    }
})

# Double click para abrir
$lstResultados.Add_MouseDoubleClick({
    try {
        $selectedIndex = $lstResultados.SelectedIndex

        if ($selectedIndex -ge 0 -and $selectedIndex -lt $script:ArquivosEncontrados.Count) {
            $originalFile = $script:ArquivosEncontrados[$selectedIndex]
            $fileName = [System.IO.Path]::GetFileName($originalFile)
            $localFile = Join-Path $script:PastaTemporaria $fileName

            if (-not (Test-Path $localFile)) {
                try {
                    Copy-Item -Path $originalFile -Destination $localFile -Force -ErrorAction Stop
                } catch {
                    $lblStatus.Text = "❌ Erro ao copiar arquivo"
                    # Write-Warning "Erro ao copiar arquivo: $_"
                    return
                }
            }

            try {
                Start-Process $localFile -ErrorAction Stop
                $lblStatus.Text = "📄 Arquivo aberto"
            } catch {
                $lblStatus.Text = "❌ Erro ao abrir PDF - Verifique se há um leitor instalado"
                # Write-Warning "Erro ao abrir arquivo: $_"
            }
        }
    } catch {
        $lblStatus.Text = "❌ Erro ao processar arquivo"
        # Write-Warning "Erro no evento MouseDoubleClick: $_"
    }
})

# Click na imagem para alternar zoom
$imgPreview.Add_MouseLeftButtonUp({
    if ($imgPreview.Source) {
        if ($imgPreview.Stretch -eq 'Uniform') {
            $imgPreview.Stretch = 'None'
            $lblStatus.Text = "🔍 Visualização em tamanho real (Clique para Ajustar)"
        } else {
            $imgPreview.Stretch = 'Uniform'
            $lblStatus.Text = "🔍 Visualização ajustada (Clique para Zoom 1:1)"
        }
    }
})

# Botão Abrir Pasta
$btnAbrirPasta.Add_Click({
    if ($script:PastaTemporaria -and (Test-Path $script:PastaTemporaria)) {
        foreach ($arquivo in $script:ArquivosEncontrados) {
            $fileName = [System.IO.Path]::GetFileName($arquivo)
            $localFile = Join-Path $script:PastaTemporaria $fileName
            
            if (-not (Test-Path $localFile)) {
                try {
                    Copy-Item -Path $arquivo -Destination $localFile -Force -ErrorAction Stop
                } catch {
                    # Write-Warning "Erro ao copiar arquivo: $($_.Exception.Message)"
                }
            }
        }
        
        Start-Process "explorer.exe" -ArgumentList $script:PastaTemporaria
        $lblStatus.Text = "📁 Pasta aberta no Explorer"
    }
})

# Cleanup ao fechar
$window.Add_Closed({
    if ($script:PastaTemporaria) {
        Remove-PastaTemporaria -Caminho $script:PastaTemporaria
    }
    if ($script:timer -and $script:timer.IsEnabled) {
        $script:timer.Stop()
    }
    # Cleanup de runspaces se estiver em execução
    if ($script:runspaceData) {
        foreach ($rs in $script:runspaceData.Runspaces) {
            if ($rs.Pipe) {
                $rs.Pipe.Stop()
                $rs.Pipe.Dispose()
            }
        }
        if ($script:runspaceData.Pool) {
            $script:runspaceData.Pool.Close()
            $script:runspaceData.Pool.Dispose()
        }
        $script:runspaceData = $null
    }
})

# Inicializar após a janela carregar
$window.Add_Loaded({
    try {
        # Garantir que overlays estejam escondidos na inicialização
        $popupOverlay.Visibility = 'Collapsed'
        $loadingOverlay.Visibility = 'Collapsed'

        # Aplicar tema inicial Light
        Toggle-Theme -IsDark $false
    }
    catch {
        # Se der erro, apenas define a variável e mantém estilos padrão do XAML
        $script:TemaAtual = "Light"
        # Write-Warning "Erro ao inicializar tema: $($_.Exception.Message)"
    }
})

# Mostrar janela
$window.ShowDialog() | Out-Null