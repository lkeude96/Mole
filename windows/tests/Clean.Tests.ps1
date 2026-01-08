# Mole Windows - Cleanup Module Tests
# Pester tests for lib/clean functionality

BeforeAll {
    # Get the windows directory path (tests are in windows/tests/)
    $script:WindowsDir = Split-Path -Parent $PSScriptRoot
    $script:LibDir = Join-Path $script:WindowsDir "lib"
    
    # Import core modules first
    . "$script:LibDir\core\base.ps1"
    . "$script:LibDir\core\log.ps1"
    . "$script:LibDir\core\ui.ps1"
    . "$script:LibDir\core\file_ops.ps1"
    
    # Import cleanup modules
    . "$script:LibDir\clean\user.ps1"
    . "$script:LibDir\clean\caches.ps1"
    . "$script:LibDir\clean\dev.ps1"
    . "$script:LibDir\clean\apps.ps1"
    . "$script:LibDir\clean\system.ps1"
    
    # Enable dry-run mode for all tests
    $env:MOLE_DRY_RUN = "1"
    Set-DryRunMode -Enabled $true
}

AfterAll {
    $env:MOLE_DRY_RUN = $null
    Set-DryRunMode -Enabled $false
}

Describe "User Cleanup Module" {
    Context "Clear-UserTempFiles" {
        It "Should have Clear-UserTempFiles function" {
            Get-Command Clear-UserTempFiles -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
        
        It "Should run without error in dry-run mode" {
            { Clear-UserTempFiles } | Should -Not -Throw
        }
    }
    
    Context "Clear-OldDownloads" {
        It "Should have Clear-OldDownloads function" {
            Get-Command Clear-OldDownloads -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
    
    Context "Clear-RecycleBin" {
        It "Should have Clear-RecycleBin function" {
            Get-Command Clear-RecycleBin -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
    
    Context "Invoke-UserCleanup" {
        It "Should have main user cleanup function" {
            Get-Command Invoke-UserCleanup -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Cache Cleanup Module" {
    Context "Browser Cache Functions" {
        It "Should have Clear-BrowserCaches function" {
            Get-Command Clear-BrowserCaches -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
        
        It "Should run browser cache cleanup without error" {
            { Clear-BrowserCaches } | Should -Not -Throw
        }
    }
    
    Context "Application Cache Functions" {
        It "Should have Clear-AppCaches function" {
            Get-Command Clear-AppCaches -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
    
    Context "Windows Update Cache" {
        It "Should have Clear-WindowsUpdateCache function" {
            Get-Command Clear-WindowsUpdateCache -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
    
    Context "Invoke-CacheCleanup" {
        It "Should have main cache cleanup function" {
            Get-Command Invoke-CacheCleanup -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Developer Tools Cleanup Module" {
    Context "Node.js Cleanup" {
        It "Should have npm cache cleanup function" {
            Get-Command Clear-NpmCache -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
    
    Context "Python Cleanup" {
        It "Should have Python cache cleanup function" {
            Get-Command Clear-PythonCaches -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
    
    Context "Go Cleanup" {
        It "Should have Go cache cleanup function" {
            Get-Command Clear-GoCaches -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
    
    Context "Rust Cleanup" {
        It "Should have Rust cache cleanup function" {
            Get-Command Clear-RustCaches -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
    
    Context "Docker Cleanup" {
        It "Should have Docker cache cleanup function" {
            Get-Command Clear-DockerCaches -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
    
    Context "Invoke-DevToolsCleanup" {
        It "Should have main dev tools cleanup function" {
            Get-Command Invoke-DevToolsCleanup -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
        
        It "Should run without error in dry-run mode" {
            { Invoke-DevToolsCleanup } | Should -Not -Throw
        }
    }
}

Describe "Apps Cleanup Module" {
    Context "Orphan Detection" {
        It "Should have Find-OrphanedAppData function" {
            Get-Command Find-OrphanedAppData -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
        
        It "Should have Clear-OrphanedAppData function" {
            Get-Command Clear-OrphanedAppData -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
    
    Context "Specific App Cleanup" {
        It "Should have Clear-OfficeCache function" {
            Get-Command Clear-OfficeCache -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
        
        It "Should have Clear-AdobeData function" {
            Get-Command Clear-AdobeData -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
    
    Context "Invoke-AppCleanup" {
        It "Should have main app cleanup function" {
            Get-Command Invoke-AppCleanup -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "System Cleanup Module" {
    Context "System Temp" {
        It "Should have Clear-SystemTempFiles function" {
            Get-Command Clear-SystemTempFiles -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
    
    Context "Windows Logs" {
        It "Should have Clear-WindowsLogs function" {
            Get-Command Clear-WindowsLogs -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
    
    Context "Windows Update Cleanup" {
        It "Should have Clear-WindowsUpdateFiles function" {
            Get-Command Clear-WindowsUpdateFiles -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
    
    Context "Memory Dumps" {
        It "Should have Clear-MemoryDumps function" {
            Get-Command Clear-MemoryDumps -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
    
    Context "Admin Requirements" {
        It "Should check for admin when needed" {
            # System cleanup should handle non-admin gracefully
            { Clear-SystemTempFiles } | Should -Not -Throw
        }
    }
    
    Context "Invoke-SystemCleanup" {
        It "Should have main system cleanup function" {
            Get-Command Invoke-SystemCleanup -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
}
