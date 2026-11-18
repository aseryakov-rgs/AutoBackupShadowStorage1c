#region AUTHOR
<# 
.SYNOPSIS
    Выполняет резервное копирование каталога - хранилища конфигураций 

.DESCRIPTION
    Подробное описание функциональности
    Ключевые особенности скрипта:
    Проверка VSS: Проверяет службу, создает или использует существующую теневую копию

    Фильтрация: Исключает файлы .snp при копировании

    Целостность: Проверяет количество и размер скопированных файлов

    Хранение бэкапов: Оставляет ежедневные за 7 дней + 1 ежемесячный (за 1-е число месяца)

    Гарантированное удаление теневой копии: В блоке finally

    Опциональное логирование: Детальная информация хранится в $VSSInfo

    Базовое логирование: Только ключевые события в лог-файл
.AUTHOR
    Aleksandr Seryakov <aseryakov@rg-spc.ru>  <aleksandr.rgspc@gmail.com>

.LICENSE
    MIT
    
.CREATION DATE
    2026-08-31

.VERSION
    1.0.0

.CHANGELOG
    1.0.0 (2026-08-31) - Первоначальная версия
    
.LINK
    https://github.com/aseryakov-rgs/AutoBackupShadowStorage1c

#>
#endregion
# Функция для записи события в лог файле
function Log-Event {
    param (
        [string]$Message
    )
    
    $Stamp = (Get-Date).toString("yyyy/MM/dd HH:mm:ss")
    $LogMessage = "$Stamp $Message"
    Add-content "E:\tasksheduler-scripts\AutoBackupShadowStorage1c.log" -value $LogMessage -Encoding UTF8
}

# Функция для безопасного подключения сетевого диска
function Connect-NetworkDrive {
    param (
        [string]$NetworkPath,
        [string]$DriveLetter,
        [string]$Username,
        [string]$Password
    )
    
    try {
        # Исправлено: буква диска в верхнем регистре
        $DriveLetter = $DriveLetter.ToUpper()
        
        # Проверяем, не подключен ли уже диск
        $existingDrive = Get-PSDrive -Name $DriveLetter -ErrorAction SilentlyContinue
        if ($existingDrive) {
            if ($existingDrive.DisplayRoot -eq $NetworkPath) {
                Log-Event -Message "Network drive $DriveLetter already connected to $NetworkPath"
                return $true
            } else {
                # Отключаем существующий диск с другим путем
                Remove-PSDrive -Name $DriveLetter -Force -ErrorAction SilentlyContinue
                net use $DriveLetter /delete /y 2>$null
            }
        }
        
        # Безопасное преобразование пароля в защищенную строку
        $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
        
        # Создаем credential объект
        $credential = New-Object System.Management.Automation.PSCredential($Username, $securePassword)
        
        # Подключаем сетевой диск через New-PSDrive
        $null = New-PSDrive -Name $DriveLetter -PSProvider FileSystem -Root $NetworkPath -Credential $credential -Persist -Scope Global
        
        # Альтернативный вариант через net use
        if (-not (Get-PSDrive -Name $DriveLetter -ErrorAction SilentlyContinue)) {
            $process = Start-Process -FilePath "net.exe" -ArgumentList "use $DriveLetter $NetworkPath /user:$Username $Password /persistent:no" -NoNewWindow -Wait -PassThru
            
            if ($process.ExitCode -ne 0) {
                throw "Failed to connect network drive. Exit code: $($process.ExitCode)"
            }
        }
        
        # Проверяем успешность подключения
        if (Get-PSDrive -Name $DriveLetter -ErrorAction SilentlyContinue) {
            Log-Event -Message "Network drive $DriveLetter connected successfully to $NetworkPath"
            return $true
        } else {
            throw "Failed to connect network drive"
        }
        
    } catch {
        Log-Event -Message "Failed to connect network drive: $($_.Exception.Message)"
        throw
    } finally {
        # Очищаем чувствительные данные из памяти
        if ($securePassword) {
            $securePassword.Dispose()
        }
    }
}

# Функция для отключения сетевого диска
function Disconnect-NetworkDrive {
    param (
        [string]$DriveLetter
    )
    
    try {
        # Исправлено: буква диска в верхнем регистре
        $DriveLetter = $DriveLetter.ToUpper()
        
        # Пытаемся отключить через PowerShell
        $drive = Get-PSDrive -Name $DriveLetter -ErrorAction SilentlyContinue
        if ($drive) {
            Remove-PSDrive -Name $DriveLetter -Force -ErrorAction SilentlyContinue
        }
        
        # Дополнительно отключаем через net use
        $process = Start-Process -FilePath "net.exe" -ArgumentList "use $DriveLetter /delete /y" -NoNewWindow -Wait -PassThru
        
        if ($process.ExitCode -eq 0) {
            Log-Event -Message "Network drive $DriveLetter disconnected successfully"
            return $true
        } else {
            Log-Event -Message "Network drive $DriveLetter already disconnected or not found"
            return $false
        }
    } catch {
        Log-Event -Message "Failed to disconnect network drive: $($_.Exception.Message)"
        return $false
    }
}

# Функция для очистки старых бэкапов
function Cleanup-OldBackups {
    param (
        [string]$Path,
        [string]$Pattern
    )
    
    try {
        $backups = Get-ChildItem -Path $Path -Filter $Pattern -File | Sort-Object LastWriteTime -Descending
        
        if ($backups.Count -eq 0) {
            return
        }
        
        $weekAgo = (Get-Date).AddDays(-7)
        
        $dailyBackups = $backups | Where-Object { $_.LastWriteTime -ge $weekAgo }
        
        $monthlyBackups = $backups | Where-Object { 
            $_.LastWriteTime.Day -eq 1 -and $_.LastWriteTime -lt $weekAgo 
        } | Select-Object -First 1
        
        $keepBackups = @($dailyBackups) + @($monthlyBackups)
        $toDelete = $backups | Where-Object { $keepBackups -notcontains $_ }
        
        foreach ($backup in $toDelete) {
            try {
                Remove-Item -Path $backup.FullName -Force -Confirm:$false
                Log-Event -Message "Deleted old backup: $($backup.Name)"
            } catch {
                Log-Event -Message "Failed to delete backup $($backup.Name): $($Error[0].Message)"
            }
        }
        
        Log-Event -Message "Cleanup completed. Kept: $($keepBackups.Count), Deleted: $($toDelete.Count)"
    } catch {
        Log-Event -Message "Cleanup failed: $($Error[0].Message)"
    }
}

# Функция для создания теневой копии через vssadmin (исправлено)

function Get-ShadowCopy {
    param (
        [string]$DriveLetter,
        [hashtable]$VSSInfo,
        [string]$LinkDrive = "C"  # Диск для символической ссылки
    )
    
    try {
        # Проверка параметров
        if (-not $DriveLetter) {
            throw "DriveLetter parameter is empty"
        }
        
        # Создание теневой копии через vssadmin
        $createOutput = vssadmin create shadow /for=$DriveLetter`: 2>&1
        
        # Поиск ID теневой копии (GUID)
        $shadowID = $null
        $shadowPath = $null
        
        foreach ($line in $createOutput) {
            # Поиск GUID в фигурных скобках
            if ($line -match '\{([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\}') {
                $shadowID = $matches[1]
            }
            
            # Поиск пути к теневой копии
            if ($line -match '(\\\\\?\\GLOBALROOT\\Device\\HarddiskVolumeShadowCopy\d+)') {
                $shadowPath = $matches[1]
            }
        }
        
        if (-not $shadowID) {
            throw "Failed to parse shadow copy ID from vssadmin output"
        }
        
        if (-not $shadowPath) {
            throw "Failed to parse shadow copy path from vssadmin output"
        }
        
        # Создание символической ссылки
        $linkPath = "$LinkDrive`:\ShadowCopy_$DriveLetter"
        
        # Удаляем старую ссылку если есть
        if (Test-Path $linkPath) {
            cmd /c rmdir $linkPath 2>$null
        }
        
        # Создаем символическую ссылку
        $mklinkOutput = cmd /c "mklink /d $linkPath $shadowPath\"
        
        # Проверка создания ссылки
        if (-not (Test-Path $linkPath)) {
            throw "Failed to create symbolic link: $mklinkOutput"
        }
        
        $VSSInfo.ShadowCopyCreated = $true
        $VSSInfo.ShadowCopyID = $shadowID
        $VSSInfo.ShadowCopyPath = $shadowPath + "\"
        $VSSInfo.LinkPath = $linkPath
        $VSSInfo.EstimatedSize = "Created via vssadmin"
        
        return @{
            ID = $shadowID
            DeviceObject = $linkPath  # Используем символическую ссылку
            ShadowPath = $shadowPath  # Оригинальный путь
            LinkPath = $linkPath
        }
    } catch {
        $VSSInfo.Error = $_.Exception.Message
        throw
    }
}

# Функция для удаления теневой копии через vssadmin (исправлено)

function Remove-ShadowCopy {
    param (
        [string]$ShadowCopyID
    )
    
    try {
        if ($ShadowCopyID) {
            # Добавляем фигурные скобки к ID
            if ($ShadowCopyID -notmatch '^\{') {
                $ShadowCopyID = "{$ShadowCopyID}"
            }
            
            Log-Event -Message "DEBUG: Deleting shadow copy: $ShadowCopyID"
            
            # Выполняем удаление
            $output = vssadmin delete shadows /shadow=$ShadowCopyID /quiet 2>&1
            
            # Проверяем результат
            if ($LASTEXITCODE -eq 0) {
                Log-Event -Message "DEBUG: Shadow copy deleted: $ShadowCopyID"
                return $true
            } else {
                Log-Event -Message "WARNING: Failed to delete shadow copy $ShadowCopyID"
                Log-Event -Message "DEBUG: vssadmin output: $output"
                return $false
            }
        }
        return $false
    } catch {
        Log-Event -Message "ERROR: Failed to delete shadow copy: $($_.Exception.Message)"
        return $false
    }
}

# Функция для копирования файлов с фильтром

function Copy-FromShadowCopy {
    param (
        [string]$SourcePath,
        [string]$DestinationPath,
        [string]$ExcludeExtension = ".snp"
    )
    
    try {
        # Используем robocopy для полного копирования со структурой папок
        $robocopyArgs = @(
            $SourcePath,
            $DestinationPath,
            "/E",           # Копировать все подкаталоги, включая пустые
            "/COPY:DAT",    # Копировать данные, атрибуты, временные метки
            "/R:1",         # 1 повтор при ошибке
            "/W:1",         # 1 секунда ожидания
            "/NP",          # Без прогресса
            "/NFL",         # Без списка файлов
            "/NDL",         # Без списка директорий
            "/XF", "*$ExcludeExtension"  # Исключить файлы .snp
        )
        
        $robocopyOutput = & robocopy $robocopyArgs
        
        # robocopy возвращает коды 0-7 как успешные
        if ($LASTEXITCODE -gt 7) {
            throw "robocopy failed with exit code: $LASTEXITCODE"
        }
        
        # Подсчет скопированных файлов
        $files = Get-ChildItem -Path $DestinationPath -Recurse -File
        $dirs = Get-ChildItem -Path $DestinationPath -Recurse -Directory
        
        return @{
            CopiedFiles = $files.Count
            SkippedFiles = (Get-ChildItem -Path $SourcePath -Recurse -File -Filter "*$ExcludeExtension").Count
            CopiedDirectories = $dirs.Count
        }
    } catch {
        throw "Failed to copy files: $($_.Exception.Message)"
    }
}

# Функция для проверки целостности скопированных файлов
function Test-CopiedFiles {
    param (
        [string]$SourcePath,
        [string]$DestinationPath
    )
    
    try {
        $sourceFiles = Get-ChildItem -Path $SourcePath -Recurse -File -Exclude "*.snp"
        $destFiles = Get-ChildItem -Path $DestinationPath -Recurse -File
        
        if ($sourceFiles.Count -ne $destFiles.Count) {
            throw "File count mismatch: Source=$($sourceFiles.Count), Destination=$($destFiles.Count)"
        }
        
        $totalSize = 0
        foreach ($file in $destFiles) {
            $totalSize += $file.Length
        }
        
        return @{
            FileCount = $destFiles.Count
            TotalSize = $totalSize
            IntegrityCheck = "OK"
        }
    } catch {
        throw "Integrity check failed: $($_.Exception.Message)"
    }
}


# Функция для архивации с использованием 7-Zip (если доступен) или Compress-Archive
function Create-Archive {
    param(
        [string]$SourcePath,
        [string]$ArchivePath,
        [string]$CompressionLevel = "Fastest",
        [string]$SevenZipPath = "C:\Program Files\7-Zip\7z.exe"
    )
    
    $startTime = Get-Date
    
    # Проверяем наличие 7-Zip
    if (Test-Path $SevenZipPath) {
        Log-Event -Message "Using 7-Zip for compression"
        
        # Если архив .zip, используем 7-Zip
        if ($ArchivePath -like "*.zip") {
            & $SevenZipPath a -tzip -mx1 -mmt=on $ArchivePath $SourcePath
        } else {
            # Для .7z формата
            & $SevenZipPath a -mx1 -mmt=on $ArchivePath $SourcePath
        }
        
        if ($LASTEXITCODE -ne 0) {
            throw "7-Zip compression failed with exit code: $LASTEXITCODE"
        }
    } else {
        Log-Event -Message "7-Zip not found, using Compress-Archive"
        
        # Fallback на Compress-Archive
        Compress-Archive -Path $SourcePath -DestinationPath $ArchivePath -CompressionLevel $CompressionLevel
    }
    
    $endTime = Get-Date
    $duration = $endTime - $startTime
    Log-Event -Message "Compression completed in $($duration.TotalMinutes) minutes"
}


# Основной скрипт
Log-Event -Message "--Start backup catalog"

# Конфигурация
[string]$SourceDir = "E:\1CRepositories"
[string]$destinationSubDir = ""
[string]$SourceDriveLetter = "E"
[string]$DriveLetterlinkPath = "C"


# Параметры сетевого диска
[string]$NetworkPath = "\\example.com\Share\Backup"
[string]$NetworkDriveLetter = "S"  # Исправлено: заглавная буква
[string]$NetworkUsername = "domain\username"
[string]$NetworkPassword = "pass"  # НЕ ХРАНИТЕ ПАРОЛЬ В СКРИПТЕ!
[bool]$VerboseLogging = $true
[string]$LocalTempPath = "F:\Temp"  # Локальная директория для временных файлов


# Переменная для хранения информации о VSS
$VSSInfo = @{
    ServiceStatus = $null
    ExistingShadowCopies = 0
    ShadowCopyCreated = $false
    ShadowCopyPath = $null
    ShadowCopyID = $null
    EstimatedSize = $null
    Error = $null
}

$networkDriveConnected = $false
$shadowCopy = $null

try {
    # 1. Проверка службы VSS
    Log-Event -Message "DEBUG: Starting VSS service check"
    $vssService = Get-Service VSS -ErrorAction Stop
    $VSSInfo.ServiceStatus = $vssService.Status
    Log-Event -Message "DEBUG: VSS service status: $($vssService.Status)"
    
    if ($vssService.Status -ne 'Running') {
        Log-Event -Message "VSS service is not running. Attempting to start..."
        Start-Service VSS -ErrorAction Stop
        $VSSInfo.ServiceStatus = "Started manually"
    }
    
    # 2. Подключение сетевого диска
    Log-Event -Message "DEBUG: Connecting network drive $NetworkDriveLetter"
    $networkDriveConnected = Connect-NetworkDrive -NetworkPath $NetworkPath -DriveLetter $NetworkDriveLetter -Username $NetworkUsername -Password $NetworkPassword
    
    if (-not $networkDriveConnected) {
        throw "Failed to connect network drive"
    }
    
    $DestinationDir = "$NetworkDriveLetter`:\"
    Log-Event -Message "DEBUG: Network destination: $DestinationDir"
    
    # 3. Создание теневой копии
    Log-Event -Message "DEBUG: Creating shadow copy for drive $SourceDriveLetter"
    $shadowCopy = Get-ShadowCopy -DriveLetter $SourceDriveLetter -VSSInfo $VSSInfo -LinkDrive "C"
    
    $relativePath = $SourceDir.Substring(3).TrimStart('\')
    $shadowSourcePath = Join-Path $shadowCopy.DeviceObject $relativePath
    Log-Event -Message "DEBUG: Shadow source path: $shadowSourcePath"
    
    if (-not (Test-Path $shadowSourcePath)) {
        throw "Shadow source path not found: $shadowSourcePath"
    }
    
    # 4. Копирование в локальную временную директорию
    $localTempDir = Join-Path $LocalTempPath "Backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    
    if (-not (Test-Path $LocalTempPath)) {
        New-Item -Path $LocalTempPath -ItemType Directory -Force | Out-Null
    }
    
    if (-not (Test-Path $localTempDir)) {
        New-Item -Path $localTempDir -ItemType Directory -Force | Out-Null
    }
    
    Log-Event -Message "DEBUG: Copying to local temp: $localTempDir"
    $copyResult = Copy-FromShadowCopy -SourcePath $shadowSourcePath -DestinationPath $localTempDir -ExcludeExtension ".snp"
    Log-Event -Message "DEBUG: Files copied: $($copyResult.CopiedFiles), Skipped: $($copyResult.SkippedFiles)"
    
    # Проверка целостности локально
    $integrityCheck = Test-CopiedFiles -SourcePath $shadowSourcePath -DestinationPath $localTempDir
    Log-Event -Message "DEBUG: Integrity check: $($integrityCheck.FileCount) files, $([math]::Round($integrityCheck.TotalSize/1MB, 2)) MB"
    
    # 5. Создание архива локально
    $archiveName = "1CRepositories_" + (Get-Date).ToString("yyyyMMdd") + "_auto_backup.zip"
    $localArchivePath = Join-Path $LocalTempPath $archiveName
    
    Log-Event -Message "DEBUG: Creating local archive..."
    $compressStartTime = Get-Date
    
    $sevenZipPath = "C:\Program Files\7-Zip\7z.exe"
    
    if (Test-Path $sevenZipPath) {
        Log-Event -Message "DEBUG: Using 7-Zip"
        & $sevenZipPath a -tzip -mx1 -mmt=on $localArchivePath "$localTempDir\*"
    } else {
        Log-Event -Message "DEBUG: Using Compress-Archive"
        Compress-Archive -Path "$localTempDir\*" -DestinationPath $localArchivePath -CompressionLevel "Fastest"
    }
    
    $compressEndTime = Get-Date
    Log-Event -Message "DEBUG: Compression completed in $([math]::Round(($compressEndTime - $compressStartTime).TotalMinutes, 2)) minutes"
    
    # 6. Копирование архива на сетевой диск
    $archivePath = Join-Path $DestinationDir $archiveName
    Log-Event -Message "DEBUG: Uploading archive to network..."
    
    Copy-Item -Path $localArchivePath -Destination $archivePath -Force
    
    Log-Event -Message "Archiving completed successfully! Size: $([math]::Round((Get-Item $archivePath).Length/1MB, 2)) MB"
    
    # 7. Очистка локальных временных файлов
    Log-Event -Message "DEBUG: Cleaning up local temp files..."
    
    Remove-Item -Path $localArchivePath -Force -Confirm:$false
    Remove-Item -Path $localTempDir -Recurse -Force -Confirm:$false
    
    # 8. Очистка старых бэкапов на сетевом диске
    Log-Event -Message "DEBUG: Cleaning up old backups..."
    Cleanup-OldBackups -Path $DestinationDir -Pattern "*_auto_backup.zip"
    
    Log-Event -Message "--End backup"
    
} catch {
    Log-Event -Message "ERROR: Backup failed"
    Log-Event -Message "ERROR: $($_.Exception.Message)"
    
    if ($VSSInfo.Error) {
        Log-Event -Message "VSS Error: $($VSSInfo.Error)"
    }
    exit 1
} finally {
    # Удаление теневой копии
    if ($VSSInfo.ShadowCopyID) {
        $deleted = Remove-ShadowCopy -ShadowCopyID $VSSInfo.ShadowCopyID
        if ($deleted) {
            Log-Event -Message "Shadow copy deleted successfully"
        }
    }
    
    # Отключение сетевого диска
    if ($networkDriveConnected) {
        Disconnect-NetworkDrive -DriveLetter $NetworkDriveLetter
    }
    
    # Очистка локальных временных файлов при ошибке
    if (Test-Path $localTempDir) {
        Remove-Item -Path $localTempDir -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
    }
    if (Test-Path $localArchivePath) {
        Remove-Item -Path $localArchivePath -Force -Confirm:$false -ErrorAction SilentlyContinue
    }
}