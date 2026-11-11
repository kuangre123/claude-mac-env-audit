#Requires -Version 5.1
<#
.SYNOPSIS
  Claude Code Windows 环境审计 —— 图形界面。

.DESCRIPTION
  调用 claude_win_env_audit.ps1 执行检测，并通过 -EventLog 事件流实时展示：
  检查项总数、已执行数量、每项结果、逐条发现和执行过程。

.PARAMETER ValidateOnly
  只校验 XAML 与控件是否完整，不显示窗口（用于测试）。

.PARAMETER AuditHome
  透传给审计脚本，指定用户主目录（测试或审计其他用户配置时使用）。
#>
param(
  [switch]$ValidateOnly,
  [string]$AuditHome = ''
)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

$script:AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:EnginePath = Join-Path (Split-Path -Parent $script:AppDir) 'claude_win_env_audit.ps1'

# WPF 需要 STA；pwsh 7 默认 MTA，自动以 -STA 重启一次
if (-not $ValidateOnly) {
  if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne [System.Threading.ApartmentState]::STA) {
    $exe = (Get-Process -Id $PID).Path
    $argList = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'))
    if ($AuditHome) { $argList += @('-AuditHome', ('"' + $AuditHome + '"')) }
    Start-Process -FilePath $exe -ArgumentList $argList | Out-Null
    exit 0
  }
}

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude Code Windows 环境审计" Height="940" Width="1260"
        WindowStartupLocation="CenterScreen" Background="#F5F7FB"
        FontFamily="Microsoft YaHei UI" FontSize="13"
        UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Window.Resources>

    <SolidColorBrush x:Key="Ink" Color="#0F172A"/>
    <SolidColorBrush x:Key="Ink2" Color="#64748B"/>
    <SolidColorBrush x:Key="Line" Color="#E9EDF5"/>
    <SolidColorBrush x:Key="Accent" Color="#2563EB"/>
    <SolidColorBrush x:Key="AccentSoft" Color="#EEF4FF"/>

    <!-- 卡片 -->
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="White"/>
      <Setter Property="CornerRadius" Value="14"/>
      <Setter Property="BorderBrush" Value="#E9EDF5"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="0"/>
    </Style>

    <!-- 卡片标题 -->
    <Style x:Key="CardTitle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#334155"/>
      <Setter Property="Margin" Value="16,13,16,7"/>
    </Style>

    <!-- 主按钮 -->
    <Style x:Key="PrimaryButton" TargetType="Button">
      <Setter Property="Background" Value="#2563EB"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Height" Value="36"/>
      <Setter Property="MinWidth" Value="96"/>
      <Setter Property="Padding" Value="20,0"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bg" Background="{TemplateBinding Background}" CornerRadius="10" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bg" Property="Background" Value="#1D4ED8"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bg" Property="Background" Value="#1E40AF"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bg" Property="Background" Value="#E5EAF3"/>
                <Setter Property="Foreground" Value="#94A3B8"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- 次按钮 -->
    <Style x:Key="GhostButton" TargetType="Button">
      <Setter Property="Background" Value="White"/>
      <Setter Property="Foreground" Value="#334155"/>
      <Setter Property="Height" Value="36"/>
      <Setter Property="Padding" Value="18,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bg" Background="{TemplateBinding Background}" CornerRadius="10"
                    BorderBrush="#DCE3EE" BorderThickness="1" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bg" Property="Background" Value="#F4F7FC"/>
                <Setter TargetName="bg" Property="BorderBrush" Value="#C3CEDE"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bg" Property="Background" Value="#EBF1F9"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bg" Property="Background" Value="#F7F9FC"/>
                <Setter TargetName="bg" Property="BorderBrush" Value="#EAEFF6"/>
                <Setter Property="Foreground" Value="#A8B3C4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- 输入框 -->
    <Style TargetType="TextBox">
      <Setter Property="Height" Value="34"/>
      <Setter Property="Background" Value="#FBFCFE"/>
      <Setter Property="Foreground" Value="#0F172A"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="CaretBrush" Value="#2563EB"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="bd" CornerRadius="9" BorderThickness="1" BorderBrush="#E1E7F2" Background="{TemplateBinding Background}">
              <ScrollViewer x:Name="PART_ContentHost" Margin="10,0" VerticalAlignment="Center" HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Hidden"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="#C9D4E6"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="#2563EB"/>
                <Setter TargetName="bd" Property="Background" Value="White"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Background" Value="#F7F9FC"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="#EDF1F7"/>
                <Setter Property="Foreground" Value="#A8B3C4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- 模式胶囊 -->
    <Style TargetType="RadioButton">
      <Setter Property="Foreground" Value="#475569"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="chip" CornerRadius="9" Background="#F3F6FB" BorderBrush="#E5EAF3" BorderThickness="1" Padding="14,6">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="chip" Property="Background" Value="#EDF2FA"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="chip" Property="Background" Value="#2563EB"/>
                <Setter TargetName="chip" Property="BorderBrush" Value="#2563EB"/>
                <Setter Property="Foreground" Value="White"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="chip" Property="Opacity" Value="0.5"/>
                <Setter Property="Cursor" Value="Arrow"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- 复选胶囊 -->
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#475569"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="chip" CornerRadius="9" Background="#F3F6FB" BorderBrush="#E5EAF3" BorderThickness="1" Padding="12,6">
              <StackPanel Orientation="Horizontal">
                <Path x:Name="tick" Data="M1,5 L4,8 L10,1" Stroke="White" StrokeThickness="1.8"
                      StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                      Visibility="Collapsed" VerticalAlignment="Center" Margin="0,0,7,0"/>
                <ContentPresenter VerticalAlignment="Center"/>
              </StackPanel>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="chip" Property="Background" Value="#EDF2FA"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="chip" Property="Background" Value="#2563EB"/>
                <Setter TargetName="chip" Property="BorderBrush" Value="#2563EB"/>
                <Setter TargetName="tick" Property="Visibility" Value="Visible"/>
                <Setter Property="Foreground" Value="White"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="chip" Property="Opacity" Value="0.5"/>
                <Setter Property="Cursor" Value="Arrow"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- 进度条 -->
    <Style TargetType="ProgressBar">
      <Setter Property="Height" Value="8"/>
      <Setter Property="Background" Value="#E9EEF7"/>
      <Setter Property="Foreground" Value="#2563EB"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid>
              <Border CornerRadius="4" Background="{TemplateBinding Background}"/>
              <Border x:Name="PART_Track"/>
              <Border x:Name="PART_Indicator" CornerRadius="4" Background="{TemplateBinding Foreground}" HorizontalAlignment="Left"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- 滚动条 -->
    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Width" Value="9"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True" Orientation="{TemplateBinding Orientation}">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False"/>
                </Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False"/>
                </Track.IncreaseRepeatButton>
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Border CornerRadius="4" Background="#CFD8E6" Margin="2"/>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="Height" Value="9"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <!-- 表格 -->
    <Style TargetType="DataGrid">
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="RowHeaderWidth" Value="0"/>
      <Setter Property="GridLinesVisibility" Value="None"/>
      <Setter Property="HeadersVisibility" Value="Column"/>
      <Setter Property="AutoGenerateColumns" Value="False"/>
      <Setter Property="IsReadOnly" Value="True"/>
      <Setter Property="CanUserAddRows" Value="False"/>
      <Setter Property="CanUserDeleteRows" Value="False"/>
      <Setter Property="CanUserResizeRows" Value="False"/>
      <Setter Property="CanUserReorderColumns" Value="False"/>
      <Setter Property="SelectionMode" Value="Single"/>
      <Setter Property="SelectionUnit" Value="FullRow"/>
      <Setter Property="RowHeight" Value="38"/>
      <Setter Property="ColumnHeaderHeight" Value="34"/>
      <Setter Property="HorizontalScrollBarVisibility" Value="Disabled"/>
      <Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
    </Style>

    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#8A97AB"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="10,0"/>
      <Setter Property="BorderThickness" Value="0,0,0,1"/>
      <Setter Property="BorderBrush" Value="#EEF2F8"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
    </Style>

    <Style TargetType="DataGridRow">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#1F2A37"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#F7FAFF"/>
        </Trigger>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="#EEF4FF"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style TargetType="DataGridCell">
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#1F2A37"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="DataGridCell">
            <Border Background="Transparent" Padding="10,0">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- 状态胶囊 -->
    <DataTemplate x:Key="StatusPill">
      <Border x:Name="pill" CornerRadius="9" Padding="10,3" HorizontalAlignment="Left" Background="#F1F5F9">
        <TextBlock x:Name="pillText" Text="{Binding Status}" FontSize="12" Foreground="#64748B"/>
      </Border>
      <DataTemplate.Triggers>
        <DataTrigger Binding="{Binding Status}" Value="正常">
          <Setter TargetName="pill" Property="Background" Value="#E7F6EF"/>
          <Setter TargetName="pillText" Property="Foreground" Value="#047857"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding Status}" Value="警告">
          <Setter TargetName="pill" Property="Background" Value="#FEF3E2"/>
          <Setter TargetName="pillText" Property="Foreground" Value="#B45309"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding Status}" Value="失败">
          <Setter TargetName="pill" Property="Background" Value="#FDECEC"/>
          <Setter TargetName="pillText" Property="Foreground" Value="#B91C1C"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding Status}" Value="已修复">
          <Setter TargetName="pill" Property="Background" Value="#E8F1FE"/>
          <Setter TargetName="pillText" Property="Foreground" Value="#1D4ED8"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding Status}" Value="运行中">
          <Setter TargetName="pill" Property="Background" Value="#E8F1FE"/>
          <Setter TargetName="pillText" Property="Foreground" Value="#1D4ED8"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding Status}" Value="跳过">
          <Setter TargetName="pill" Property="Background" Value="#F1F5F9"/>
          <Setter TargetName="pillText" Property="Foreground" Value="#94A3B8"/>
        </DataTrigger>
      </DataTemplate.Triggers>
    </DataTemplate>

    <!-- 级别胶囊 -->
    <DataTemplate x:Key="LevelPill">
      <Border x:Name="pill" CornerRadius="9" Padding="10,3" HorizontalAlignment="Left" Background="#F1F5F9">
        <TextBlock x:Name="pillText" Text="{Binding Level}" FontSize="12" Foreground="#64748B"/>
      </Border>
      <DataTemplate.Triggers>
        <DataTrigger Binding="{Binding Level}" Value="正常">
          <Setter TargetName="pill" Property="Background" Value="#E7F6EF"/>
          <Setter TargetName="pillText" Property="Foreground" Value="#047857"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding Level}" Value="警告">
          <Setter TargetName="pill" Property="Background" Value="#FEF3E2"/>
          <Setter TargetName="pillText" Property="Foreground" Value="#B45309"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding Level}" Value="失败">
          <Setter TargetName="pill" Property="Background" Value="#FDECEC"/>
          <Setter TargetName="pillText" Property="Foreground" Value="#B91C1C"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding Level}" Value="已修复">
          <Setter TargetName="pill" Property="Background" Value="#E8F1FE"/>
          <Setter TargetName="pillText" Property="Foreground" Value="#1D4ED8"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding Level}" Value="信息">
          <Setter TargetName="pill" Property="Background" Value="#F1F5F9"/>
          <Setter TargetName="pillText" Property="Foreground" Value="#64748B"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding Level}" Value="预览">
          <Setter TargetName="pill" Property="Background" Value="#F3ECFE"/>
          <Setter TargetName="pillText" Property="Foreground" Value="#7C3AED"/>
        </DataTrigger>
      </DataTemplate.Triggers>
    </DataTemplate>

  </Window.Resources>

  <Grid Margin="22,18,22,18">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="190"/>
    </Grid.RowDefinitions>

    <!-- 头部 -->
    <Grid Grid.Row="0" Margin="0,0,0,14">
      <StackPanel>
        <TextBlock Text="Claude Code Windows 环境审计" FontSize="22" FontWeight="Bold" Foreground="#0F172A"/>
        <TextBlock x:Name="TxtHint" Text="" FontSize="12" Foreground="#8A97AB" Margin="0,5,0,0"/>
      </StackPanel>
      <Border x:Name="StatusPill" HorizontalAlignment="Right" VerticalAlignment="Top" Background="#EEF4FF" CornerRadius="14" Padding="14,6">
        <StackPanel Orientation="Horizontal">
          <Ellipse x:Name="StatusDot" Width="7" Height="7" Fill="#2563EB" Margin="0,0,8,0" VerticalAlignment="Center"/>
          <TextBlock x:Name="TxtStatus" Text="就绪" FontWeight="SemiBold" Foreground="#2563EB"/>
        </StackPanel>
      </Border>
    </Grid>

    <!-- 控制区 -->
    <Border Grid.Row="1" Style="{StaticResource Card}" Margin="0,0,0,12">
      <Grid Margin="16,14,16,14">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <StackPanel Grid.Row="0" Orientation="Horizontal">
          <TextBlock Text="模式" VerticalAlignment="Center" FontSize="12" Foreground="#8A97AB" Margin="0,0,10,0"/>
          <RadioButton x:Name="RdoPreview" Content="预览" GroupName="Mode" Margin="0,0,6,0"/>
          <RadioButton x:Name="RdoCheck" Content="只检测" GroupName="Mode" IsChecked="True" Margin="0,0,6,0"/>
          <RadioButton x:Name="RdoFix" Content="自动修复" GroupName="Mode" Margin="0,0,22,0"/>
          <TextBlock Text="目标时区" VerticalAlignment="Center" FontSize="12" Foreground="#8A97AB" Margin="0,0,8,0"/>
          <TextBox x:Name="TxtTz" Width="150" Margin="0,0,18,0" ToolTip="例如 Asia/Tokyo 或 Tokyo Standard Time"/>
          <TextBlock Text="目标国家" VerticalAlignment="Center" FontSize="12" Foreground="#8A97AB" Margin="0,0,8,0"/>
          <TextBox x:Name="TxtCountry" Width="58" Margin="0,0,18,0" ToolTip="两位国家代码，例如 JP、SG、US"/>
          <CheckBox x:Name="ChkOffline" Content="跳过联网检测" VerticalAlignment="Center" Margin="0,0,8,0"/>
          <CheckBox x:Name="ChkForce" Content="允许清理第三方 API 痕迹" VerticalAlignment="Center"
                    ToolTip="勾选后等价于 -Force：不再逐个询问，直接清理明确匹配的第三方 base URL / 代理字段"/>
        </StackPanel>
        <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,12,0,0">
          <Button x:Name="BtnStart" Content="开始检查" Style="{StaticResource PrimaryButton}" Margin="0,0,8,0"/>
          <Button x:Name="BtnStop" Content="停止" Style="{StaticResource GhostButton}" Width="88" IsEnabled="False" Margin="0,0,8,0"/>
          <Button x:Name="BtnReport" Content="打开报告目录" Style="{StaticResource GhostButton}" IsEnabled="False" Margin="0,0,8,0"/>
          <Button x:Name="BtnAdmin" Content="以管理员身份重启" Style="{StaticResource GhostButton}" IsEnabled="False"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- 进度与指标 -->
    <Border Grid.Row="2" Style="{StaticResource Card}" Margin="0,0,0,12">
      <StackPanel Margin="18,15,18,16">
        <Grid>
          <TextBlock Text="执行进度" FontSize="12" Foreground="#8A97AB"/>
          <TextBlock x:Name="TxtProgress" Text="已执行 0 / 0 项" HorizontalAlignment="Right" FontSize="12" Foreground="#8A97AB"/>
        </Grid>
        <ProgressBar x:Name="PbProgress" Maximum="100" Value="0" Margin="0,9,0,0"/>
        <StackPanel Orientation="Horizontal" Margin="0,16,0,0">
          <StackPanel Width="84">
            <TextBlock Text="检查项" FontSize="11" Foreground="#9AA6B8"/>
            <TextBlock x:Name="TxtTotal" Text="0" FontSize="21" FontWeight="Bold" Foreground="#0F172A" Margin="0,3,0,0"/>
          </StackPanel>
          <Border Width="1" Background="#EEF2F8" Margin="0,3,18,3"/>
          <StackPanel Width="84">
            <TextBlock Text="已执行" FontSize="11" Foreground="#9AA6B8"/>
            <TextBlock x:Name="TxtDone" Text="0" FontSize="21" FontWeight="Bold" Foreground="#0F172A" Margin="0,3,0,0"/>
          </StackPanel>
          <Border Width="1" Background="#EEF2F8" Margin="0,3,18,3"/>
          <StackPanel Width="84">
            <TextBlock Text="正常" FontSize="11" Foreground="#9AA6B8"/>
            <TextBlock x:Name="TxtOk" Text="0" FontSize="21" FontWeight="Bold" Foreground="#0F172A" Margin="0,3,0,0"/>
          </StackPanel>
          <Border Width="1" Background="#EEF2F8" Margin="0,3,18,3"/>
          <StackPanel Width="84">
            <TextBlock Text="警告" FontSize="11" Foreground="#9AA6B8"/>
            <TextBlock x:Name="TxtWarn" Text="0" FontSize="21" FontWeight="Bold" Foreground="#0F172A" Margin="0,3,0,0"/>
          </StackPanel>
          <Border Width="1" Background="#EEF2F8" Margin="0,3,18,3"/>
          <StackPanel Width="84">
            <TextBlock Text="已修复" FontSize="11" Foreground="#9AA6B8"/>
            <TextBlock x:Name="TxtFixed" Text="0" FontSize="21" FontWeight="Bold" Foreground="#0F172A" Margin="0,3,0,0"/>
          </StackPanel>
          <Border Width="1" Background="#EEF2F8" Margin="0,3,18,3"/>
          <StackPanel Width="84">
            <TextBlock Text="失败" FontSize="11" Foreground="#9AA6B8"/>
            <TextBlock x:Name="TxtFail" Text="0" FontSize="21" FontWeight="Bold" Foreground="#0F172A" Margin="0,3,0,0"/>
          </StackPanel>
          <Border Width="1" Background="#EEF2F8" Margin="0,3,18,3"/>
          <StackPanel Width="84">
            <TextBlock Text="问题" FontSize="11" Foreground="#9AA6B8"/>
            <TextBlock x:Name="TxtIssues" Text="0" FontSize="21" FontWeight="Bold" Foreground="#0F172A" Margin="0,3,0,0"/>
          </StackPanel>
        </StackPanel>
      </StackPanel>
    </Border>

    <!-- 检查项 + 执行过程 -->
    <Grid Grid.Row="3" Margin="0,0,0,12">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="480"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <Border Grid.Column="0" Style="{StaticResource Card}" Margin="0,0,12,0">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <TextBlock Grid.Row="0" Text="检查项状态" Style="{StaticResource CardTitle}"/>
          <DataGrid Grid.Row="1" x:Name="DgChecks">
            <DataGrid.Columns>
              <DataGridTextColumn Header="检查项" Binding="{Binding Title}" Width="*"/>
              <DataGridTemplateColumn Header="状态" Width="104" CellTemplate="{StaticResource StatusPill}"/>
              <DataGridTextColumn Header="结果" Binding="{Binding Detail}" Width="176"/>
            </DataGrid.Columns>
          </DataGrid>
        </Grid>
      </Border>

      <Border Grid.Column="1" Style="{StaticResource Card}">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <TextBlock Grid.Row="0" Text="执行过程" Style="{StaticResource CardTitle}"/>
          <RichTextBox Grid.Row="1" x:Name="RtbLog" IsReadOnly="True" BorderThickness="0" Background="Transparent"
                       Margin="10,0,6,8" Padding="4,2"
                       FontFamily="Consolas" FontSize="12"
                       VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"/>
        </Grid>
      </Border>
    </Grid>

    <!-- 执行结果 -->
    <Border Grid.Row="4" Style="{StaticResource Card}">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="执行结果 · 逐条发现" Style="{StaticResource CardTitle}"/>
        <DataGrid Grid.Row="1" x:Name="DgFindings">
          <DataGrid.Columns>
            <DataGridTemplateColumn Header="级别" Width="92" CellTemplate="{StaticResource LevelPill}"/>
            <DataGridTextColumn Header="检查项" Binding="{Binding Section}" Width="190"/>
            <DataGridTextColumn Header="内容" Binding="{Binding Message}" Width="*"/>
          </DataGrid.Columns>
        </DataGrid>
      </Grid>
    </Border>
  </Grid>
</Window>

'@

try {
  $window = [System.Windows.Markup.XamlReader]::Parse($xaml)
} catch {
  Write-Host ('[失败] XAML 解析失败: ' + $_.Exception.Message)
  exit 1
}

$required = @(
  'TxtStatus', 'TxtHint', 'StatusPill', 'StatusDot', 'RdoPreview', 'RdoCheck', 'RdoFix', 'TxtTz', 'TxtCountry', 'ChkOffline', 'ChkForce',
  'BtnStart', 'BtnStop', 'BtnReport', 'BtnAdmin', 'PbProgress', 'TxtProgress',
  'TxtTotal', 'TxtDone', 'TxtOk', 'TxtWarn', 'TxtFixed', 'TxtFail', 'TxtIssues',
  'DgChecks', 'RtbLog', 'DgFindings'
)
$missing = @()
foreach ($name in $required) {
  if ($null -eq $window.FindName($name)) { $missing += $name }
}
if ($missing.Count -gt 0) {
  Write-Host ('[失败] 缺少控件: ' + ($missing -join ', '))
  exit 1
}

if ($ValidateOnly) {
  Write-Host 'XAML OK'
  exit 0
}

# ------------------------------------------------------------
# 控件与状态
# ------------------------------------------------------------
$script:Ui = @{}
foreach ($name in $required) { $script:Ui[$name] = $window.FindName($name) }
$script:Ui.Window = $window

$script:SectionTable = @(
  [pscustomobject]@{ Key = 'os'; Title = '系统' },
  [pscustomobject]@{ Key = 'timezone'; Title = '时区' },
  [pscustomobject]@{ Key = 'system-proxy'; Title = '系统代理' },
  [pscustomobject]@{ Key = 'env'; Title = '环境变量' },
  [pscustomobject]@{ Key = 'shell-startup'; Title = 'Shell 启动文件' },
  [pscustomobject]@{ Key = 'package-managers'; Title = 'Node 包管理器代理配置' },
  [pscustomobject]@{ Key = 'git'; Title = 'Git 代理配置' },
  [pscustomobject]@{ Key = 'claude-configs'; Title = 'Claude / Router 配置文件' },
  [pscustomobject]@{ Key = 'hosts'; Title = 'hosts 文件' },
  [pscustomobject]@{ Key = 'dns'; Title = 'DNS' },
  [pscustomobject]@{ Key = 'exit-ip'; Title = '出口 IP' },
  [pscustomobject]@{ Key = 'anthropic'; Title = 'Anthropic 端点连通性' }
)

$script:Run = @{
  Running       = $false
  Process       = $null
  EventPath     = ''
  ReadIndex     = 0
  Timer         = $null
  Checks        = @{}
  Done          = $false
  Total         = 0
  Completed     = 0
  Ok            = 0
  Warn          = 0
  Fixed         = 0
  Fail          = 0
  Info          = 0
  CurrentTitle  = ''
  ReportFile    = ''
  ReportDir     = ''
}

function Get-LevelColor {
  param([string]$Level)
  switch ($Level) {
    '正常' { return '#0F766E' }
    '警告' { return '#B45309' }
    '失败' { return '#DC2626' }
    '已修复' { return '#1D4ED8' }
    '信息' { return '#64748B' }
    '预览' { return '#7C3AED' }
    default { return '#374151' }
  }
}

function Get-UiBrush {
  param([string]$Color)
  try {
    return New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Color))
  } catch {
    return New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#374151'))
  }
}

function Set-RunningUi {
  param([bool]$Running)
  $ui = $script:Ui
  $ui.BtnStart.IsEnabled = -not $Running
  $ui.BtnStop.IsEnabled = $Running
  $ui.RdoPreview.IsEnabled = -not $Running
  $ui.RdoCheck.IsEnabled = -not $Running
  $ui.RdoFix.IsEnabled = -not $Running
  $ui.TxtTz.IsEnabled = -not $Running
  $ui.TxtCountry.IsEnabled = -not $Running
  $ui.ChkOffline.IsEnabled = -not $Running
  $ui.ChkForce.IsEnabled = -not $Running
}

function Add-LogLine {
  param([string]$Text = '', [string]$Color = '#374151')
  try {
    $doc = $script:Ui.RtbLog.Document
    $para = New-Object System.Windows.Documents.Paragraph
    $para.Margin = New-Object System.Windows.Thickness(0)
    $run = New-Object System.Windows.Documents.Run($Text)
    $run.Foreground = Get-UiBrush -Color $Color
    [void]$para.Inlines.Add($run)
    [void]$doc.Blocks.Add($para)
    $script:Ui.RtbLog.ScrollToEnd()
  } catch {
    # 日志渲染失败不影响运行
  }
}

function Get-StatusPillBackground {
  param([string]$Color)
  switch ($Color) {
    '#047857' { return '#E7F6EF' }
    '#059669' { return '#E7F6EF' }
    '#2563EB' { return '#EEF4FF' }
    '#B45309' { return '#FEF3E2' }
    '#DC2626' { return '#FDECEC' }
    '#B91C1C' { return '#FDECEC' }
    default { return '#F1F5F9' }
  }
}

function Set-Status {
  param([string]$Text, [string]$Color = '#2563EB')
  try {
    $script:Ui.TxtStatus.Text = $Text
    $brush = Get-UiBrush -Color $Color
    $script:Ui.TxtStatus.Foreground = $brush
    $script:Ui.StatusDot.Fill = $brush
    $script:Ui.StatusPill.Background = Get-UiBrush -Color (Get-StatusPillBackground -Color $Color)
  } catch { }
}

function Test-IsAdmin {
  try {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch {
    return $false
  }
}

function Update-Counters {
  $ui = $script:Ui
  $ui.TxtTotal.Text = [string]$script:Run.Total
  $ui.TxtDone.Text = [string]$script:Run.Completed
  $ui.TxtOk.Text = [string]$script:Run.Ok
  $ui.TxtWarn.Text = [string]$script:Run.Warn
  $ui.TxtFixed.Text = [string]$script:Run.Fixed
  $ui.TxtFail.Text = [string]$script:Run.Fail
  $ui.TxtIssues.Text = [string]($script:Run.Warn + $script:Run.Fail)

  # 有问题时才上色，保持整体冷静
  $ui.TxtFail.Foreground = Get-UiBrush -Color $(if ($script:Run.Fail -gt 0) { '#DC2626' } else { '#0F172A' })
  $ui.TxtWarn.Foreground = Get-UiBrush -Color $(if ($script:Run.Warn -gt 0) { '#B45309' } else { '#0F172A' })
  $ui.TxtIssues.Foreground = Get-UiBrush -Color $(if (($script:Run.Warn + $script:Run.Fail) -gt 0) { '#B45309' } else { '#0F172A' })
}

function Update-Progress {
  $ui = $script:Ui
  if ($script:Run.Total -gt 0) {
    $ui.PbProgress.Value = [Math]::Min(100, (100.0 * $script:Run.Completed / $script:Run.Total))
  } else {
    $ui.PbProgress.Value = 0
  }
  $ui.TxtProgress.Text = ('已执行 ' + $script:Run.Completed + ' / ' + $script:Run.Total + ' 项')
}

function Get-StatusFromCounts {
  param([int]$Ok, [int]$Warn, [int]$Fixed, [int]$Fail)
  if ($Fail -gt 0) { return '失败' }
  if ($Warn -gt 0) { return '警告' }
  if ($Fixed -gt 0) { return '已修复' }
  if ($Ok -gt 0) { return '正常' }
  return '信息'
}

function Reset-View {
  $ui = $script:Ui
  $ui.RtbLog.Document.Blocks.Clear()
  $ui.DgFindings.Items.Clear()
  $ui.DgChecks.Items.Clear()
  $script:Run = @{
    Running      = $true
    Process      = $null
    EventPath    = ''
    ReadIndex    = 0
    Timer        = $script:Run.Timer
    Checks       = @{}
    Done         = $false
    Total        = $script:SectionTable.Count
    Completed    = 0
    Ok           = 0
    Warn         = 0
    Fixed        = 0
    Fail         = 0
    Info         = 0
    CurrentTitle = ''
    ReportFile   = ''
    ReportDir    = ''
  }
  foreach ($section in $script:SectionTable) {
    $item = [pscustomobject]@{
      Key     = $section.Key
      Title   = $section.Title
      Status  = '等待'
      Detail  = '—'
    }
    $script:Run.Checks[$section.Key] = $item
    [void]$ui.DgChecks.Items.Add($item)
  }
  $ui.PbProgress.Value = 0
  Update-Counters
  Update-Progress
}

function Add-Finding {
  param([string]$Level, [string]$Message)
  if ($script:Ui.DgFindings.Items.Count -ge 800) { return }
  $row = [pscustomobject]@{
    Level   = $Level
    Section = $script:Run.CurrentTitle
    Message = $Message
  }
  [void]$script:Ui.DgFindings.Items.Add($row)
}

function Handle-Event {
  param($Evt)
  if ($null -eq $Evt) { return }
  $type = [string]$Evt.type
  switch ($type) {
    'meta' {
      $script:Run.Total = [int]$Evt.total
      Update-Counters
      Update-Progress
      Add-LogLine ('模式: ' + [string]$Evt.mode + '；共 ' + $script:Run.Total + ' 个检查项') '#6B7280'
      Add-LogLine ''
    }
    'section-start' {
      $script:Run.CurrentTitle = [string]$Evt.title
      $item = $script:Run.Checks[[string]$Evt.section]
      if ($null -ne $item) {
        $item.Status = '运行中'
        $item.Detail = '—'
        $script:Ui.DgChecks.Items.Refresh()
      }
      Add-LogLine ('== ' + [string]$Evt.title + ' ==') '#1F2A37'
    }
    'finding' {
      $level = [string]$Evt.level
      $message = [string]$Evt.message
      Add-LogLine ('[' + $level + '] ' + $message) (Get-LevelColor -Level $level)
      Add-Finding -Level $level -Message $message
    }
    'section-end' {
      $item = $script:Run.Checks[[string]$Evt.section]
      $ok = [int]$Evt.ok
      $warn = [int]$Evt.warn
      $fixed = [int]$Evt.fixed
      $fail = [int]$Evt.fail
      $info = [int]$Evt.info
      if ($null -ne $item) {
        $item.Status = Get-StatusFromCounts -Ok $ok -Warn $warn -Fixed $fixed -Fail $fail
        $detail = '正常 ' + $ok + ' / 警告 ' + $warn
        if ($fixed -gt 0) { $detail = $detail + ' / 修复 ' + $fixed }
        if ($fail -gt 0) { $detail = $detail + ' / 失败 ' + $fail }
        $item.Detail = $detail
        $script:Ui.DgChecks.Items.Refresh()
      }
      $script:Run.Ok += $ok
      $script:Run.Warn += $warn
      $script:Run.Fixed += $fixed
      $script:Run.Fail += $fail
      $script:Run.Info += $info
      $script:Run.Completed++
      Update-Counters
      Update-Progress
    }
    'done' {
      $script:Run.Done = $true
      $script:Run.Running = $false
      $script:Run.Total = [int]$Evt.total
      $script:Run.Completed = [int]$Evt.total
      $script:Run.Ok = [int]$Evt.ok
      $script:Run.Warn = [int]$Evt.warn
      $script:Run.Fixed = [int]$Evt.fixed
      $script:Run.Fail = [int]$Evt.fail
      $script:Run.Info = [int]$Evt.info
      $script:Run.ReportFile = [string]$Evt.reportFile
      $script:Run.ReportDir = Split-Path -Parent ([string]$Evt.reportFile)
      Update-Counters
      Update-Progress
      if ($script:Run.Timer) { $script:Run.Timer.Stop() }
      Set-RunningUi -Running $false
      $script:Ui.BtnReport.IsEnabled = $true
      Add-LogLine ''
      Add-LogLine ('[完成] 检查项=' + $Evt.total + ' 正常=' + $Evt.ok + ' 警告=' + $Evt.warn + ' 已修复=' + $Evt.fixed + ' 失败=' + $Evt.fail) '#047857'
      if (-not [bool]$Evt.reportSaved) {
        Add-LogLine ('[警告] 报告未能写入（目录不可写）: ' + $Evt.reportFile) '#B45309'
        $script:Ui.BtnReport.IsEnabled = $true
      } else {
        Add-LogLine ('[信息] 报告已保存: ' + $Evt.reportFile) '#6B7280'
      }
      Set-Status '完成' '#047857'
    }
    default { }
  }
}

function Read-NewEvents {
  $path = $script:Run.EventPath
  if (-not $path) { return }
  if (-not (Test-Path -LiteralPath $path)) { return }
  try {
    $lines = [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)
  } catch {
    return
  }
  if ($lines.Count -le $script:Run.ReadIndex) { return }
  $consumed = $script:Run.ReadIndex
  for ($i = $script:Run.ReadIndex; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    if ([string]::IsNullOrWhiteSpace($line)) { $consumed = $i + 1; continue }
    $evt = $null
    try {
      $evt = $line | ConvertFrom-Json
    } catch {
      # 可能读到写入中的半行，保留位置等下一次轮询
      break
    }
    Handle-Event -Evt $evt
    $consumed = $i + 1
  }
  $script:Run.ReadIndex = $consumed
}

function Test-ProcessFinished {
  $proc = $script:Run.Process
  if ($null -eq $proc) { return }
  if ($script:Run.Done) { return }
  if (-not $proc.HasExited) { return }

  # 进程退出前可能刚写完 done 事件，先补读两次，避免误判为失败
  Read-NewEvents
  if (-not $script:Run.Done) {
    Start-Sleep -Milliseconds 250
    Read-NewEvents
  }
  if ($script:Run.Done) { return }

  if ($script:Run.Timer) { $script:Run.Timer.Stop() }
  $script:Run.Running = $false
  Set-RunningUi -Running $false
  Add-LogLine ''
  Add-LogLine ('[失败] 审计进程已退出（退出码 ' + $proc.ExitCode + '），未收到完成事件。') '#B91C1C'
  Set-Status ('已退出（' + $proc.ExitCode + '）') '#B91C1C'
}

function Update-RunUI {
  Read-NewEvents
  Test-ProcessFinished
}

function Start-AuditRun {
  if ($script:Run.Running) { return }

  $mode = 1
  if ([bool]$script:Ui.RdoPreview.IsChecked) { $mode = 0 }
  elseif ([bool]$script:Ui.RdoFix.IsChecked) { $mode = 2 }
  $tz = $script:Ui.TxtTz.Text.Trim()
  $country = $script:Ui.TxtCountry.Text.Trim().ToUpperInvariant()
  if ($country -and $country -notmatch '^[A-Z]{2}$') {
    Add-LogLine '[错误] 目标国家必须是两位国家代码，例如 JP、SG、US' '#B91C1C'
    Set-Status '参数错误' '#B91C1C'
    return
  }

  Reset-View
  $script:Ui.DgChecks.Items.Refresh()
  Add-LogLine '正在启动审计...' '#6B7280'
  Set-Status '运行中' '#2563EB'

  $runDir = Join-Path ([System.IO.Path]::GetTempPath()) ('claude-win-env-audit-gui\' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $PID)
  try {
    New-Item -ItemType Directory -Force -Path $runDir -ErrorAction Stop | Out-Null
  } catch {
    Add-LogLine ('[失败] 无法创建运行目录: ' + $runDir + ' : ' + $_.Exception.Message) '#B91C1C'
    Set-Status '启动失败' '#B91C1C'
    return
  }

  $script:Run.EventPath = Join-Path $runDir 'events.jsonl'

  $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $script:EnginePath + '"'))
  if ($mode -eq 0) { $argList += '-DryRun' }
  elseif ($mode -eq 1) { $argList += '-CheckOnly' }
  if ($tz) { $argList += @('-TargetTz', ('"' + $tz + '"')) }
  if ($country) { $argList += @('-TargetCountry', $country) }
  if ([bool]$script:Ui.ChkOffline.IsChecked) { $argList += '-Offline' }
  if ($AuditHome) { $argList += @('-AuditHome', ('"' + $AuditHome + '"')) }
  $argList += @('-EventLog', ('"' + $script:Run.EventPath + '"'))
  $argList += '-NonInteractive'
  if ([bool]$script:Ui.ChkForce.IsChecked) { $argList += '-Force' }

  try {
    $script:Run.Process = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -PassThru -WindowStyle Hidden
  } catch {
    Add-LogLine ('[失败] 无法启动审计进程: ' + $_.Exception.Message) '#B91C1C'
    Set-Status '启动失败' '#B91C1C'
    return
  }

  $script:Run.Running = $true
  Set-RunningUi -Running $true
  $script:Ui.BtnReport.IsEnabled = $false
  if ($null -eq $script:Run.Timer) {
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(150)
    $timer.Add_Tick({ Update-RunUI })
    $script:Run.Timer = $timer
  }
  $script:Run.Timer.Start()
}

function Stop-AuditRun {
  $proc = $script:Run.Process
  if ($null -ne $proc -and -not $proc.HasExited) {
    try { $proc.Kill() } catch { }
  }
  if ($script:Run.Timer) { $script:Run.Timer.Stop() }
  if (-not $script:Run.Done) {
    $script:Run.Running = $false
    Set-RunningUi -Running $false
    Add-LogLine ''
    Add-LogLine '[信息] 已手动停止。' '#B45309'
    Set-Status '已停止' '#B45309'
  }
}

function Open-Report {
  $target = $script:Run.ReportFile
  if ($target -and (Test-Path -LiteralPath $target)) {
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"' + $target + '"')
    return
  }
  $dir = $script:Run.ReportDir
  if ($dir -and (Test-Path -LiteralPath $dir)) {
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $dir + '"')
    return
  }
  $fallback = Join-Path $env:USERPROFILE '.claude-win-env-audit'
  if (Test-Path -LiteralPath $fallback) {
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $fallback + '"')
  }
}

function Restart-Elevated {
  try {
    $argList = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'))
    if ($AuditHome) { $argList += @('-AuditHome', ('"' + $AuditHome + '"')) }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs | Out-Null
    $script:Ui.Window.Close()
  } catch {
    Add-LogLine ('[错误] 提权启动失败: ' + $_.Exception.Message) '#B91C1C'
  }
}

# ------------------------------------------------------------
# 事件绑定
# ------------------------------------------------------------
$script:Ui.BtnStart.Add_Click({ Start-AuditRun })
$script:Ui.BtnStop.Add_Click({ Stop-AuditRun })
$script:Ui.BtnReport.Add_Click({ Open-Report })
$script:Ui.BtnAdmin.Add_Click({ Restart-Elevated })
$script:Ui.Window.Add_Closed({
  try {
    if ($null -ne $script:Run.Process -and -not $script:Run.Process.HasExited) {
      $script:Run.Process.Kill()
    }
  } catch { }
})

# 初始状态
Reset-View
$script:Run.Running = $false
Set-RunningUi -Running $false
if (Test-IsAdmin) {
  $script:Ui.BtnAdmin.IsEnabled = $false
  $script:Ui.TxtHint.Text = '当前已具备管理员权限，系统级修复（时区、WinHTTP、hosts）可执行。'
  Add-LogLine '[信息] 当前已具备管理员权限。' '#6B7280'
} else {
  $script:Ui.BtnAdmin.IsEnabled = $true
  $script:Ui.TxtHint.Text = '当前未以管理员身份运行：时区、WinHTTP、hosts、机器级环境变量的修复会被跳过；可点右侧按钮提权重启。'
  Add-LogLine '[信息] 当前未以管理员身份运行，系统级修复会被跳过。' '#B45309'
}
Add-LogLine '[信息] 选择模式后点“开始”。默认“只检测”不会修改任何配置。' '#6B7280'
Add-LogLine ''

if (-not (Test-Path -LiteralPath $script:EnginePath)) {
  Add-LogLine ('[失败] 找不到审计脚本: ' + $script:EnginePath) '#B91C1C'
}

[void]$window.ShowDialog()
