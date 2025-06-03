//<?php
/**
 * AutoSnapshot 3.x
 *
 * Automatic database snapshot backup plugin for Evolution CMS 3.x
 *
 * @author    Nicola Lambathakis http://www.tattoocms.it/
 * @category    plugin
 * @version     1.3.3
 * @license	 http://www.gnu.org/copyleft/gpl.html GNU Public License (GPL)
 * @internal    @events OnUserLogin,OnBeforeUserLogout
 * @internal @properties &backupPath=Backup Path;string;assets/backup/ &keepBackups=Number of snapshots to keep;string;10 &backup_at=Run Backup at:;menu;Login,Logout,Both;Logout &allow_backup=Run Backup for:;menu;ThisRolesOnly,ThisUsersOnly;ThisRolesOnly &this_roles=Role IDs (comma separated):;string;1 &this_users=User IDs (comma separated):;string;1 &debugMode=Debug Mode;menu;false,true;false
 * @internal    @modx_category Admin
 */

// Prevent direct execution
if (!defined('MODX_BASE_PATH')) {
    die('Direct access to this file is not allowed.');
}

// Log function
function autoBackupLog($message, $debugMode = false) {
    if ($debugMode === 'true' || $debugMode === true) {
        $logFile = MODX_BASE_PATH . 'assets/backup_log_3x.txt';
        $timestamp = date('Y-m-d H:i:s');
        file_put_contents($logFile, "[{$timestamp}] {$message}" . PHP_EOL, FILE_APPEND);
    }
}

// Initial log
autoBackupLog("--- START AUTOSNAPSHOT 3.x ---", $debugMode);

// Settings
$keepBackups = isset($keepBackups) && is_numeric($keepBackups) ? (int)$keepBackups : 10;
$backupPath = isset($backupPath) && !empty($backupPath) ? $backupPath : 'assets/backup/';
$backup_at = isset($backup_at) ? $backup_at : 'Logout';
$allow_backup = isset($allow_backup) ? $allow_backup : 'ThisRolesOnly';
$this_roles = isset($this_roles) ? trim($this_roles) : '1';
$this_users = isset($this_users) ? trim($this_users) : '1';

autoBackupLog("Settings: backupPath={$backupPath}, keepBackups={$keepBackups}, backup_at={$backup_at}, allow_backup={$allow_backup}", $debugMode);

// Supported events
$evtName = EvolutionCMS()->event->name ?? 'Unknown';
autoBackupLog("Event triggered: {$evtName}", $debugMode);

// Check if event is supported
$validEvents = ['OnUserLogin', 'OnBeforeUserLogout'];
if (!in_array($evtName, $validEvents)) {
    autoBackupLog("Unsupported event: {$evtName}", $debugMode);
    return;
}

// Check if backup should run for this specific event
$should_backup = false;
switch ($backup_at) {
    case 'Login':
        $should_backup = ($evtName === 'OnUserLogin');
        break;
    case 'Logout':
        $should_backup = ($evtName === 'OnBeforeUserLogout');
        break;
    case 'Both':
        $should_backup = true; // For all supported events
        break;
}

if (!$should_backup) {
    autoBackupLog("Backup skipped: event {$evtName} not enabled (setting: {$backup_at})", $debugMode);
    return;
}

// CORRECT USER RETRIEVAL for Evolution CMS 3.x
$run_backup = false;
$current_user = 0;
$current_role = 0;
$username = 'admin';

// Method 1: Use Evolution CMS 3.x native APIs
try {
    if (method_exists(EvolutionCMS(), 'getLoginUserID')) {
        $current_user = EvolutionCMS()->getLoginUserID('mgr');
        if ($current_user) {
            autoBackupLog("Manager user found via API: {$current_user}", $debugMode);
            
            // Use native APIs to get user info
            if (method_exists(EvolutionCMS(), 'getUserInfo')) {
                $userInfo = EvolutionCMS()->getUserInfo($current_user);
                if ($userInfo && isset($userInfo['username'])) {
                    $username = $userInfo['username'];
                    $current_role = $userInfo['role'] ?? 0;
                    autoBackupLog("Username from API: {$username}, role: {$current_role}", $debugMode);
                }
            }
            $userType = 'manager';
        }
    }
} catch (Exception $e) {
    autoBackupLog("API getUserID error: " . $e->getMessage(), $debugMode);
}

// Method 2: Fallback to sessions if API doesn't work
if (!$current_user) {
    if (isset($_SESSION['mgrInternalKey']) && $_SESSION['mgrInternalKey'] > 0) {
        $current_user = $_SESSION['mgrInternalKey'];
        $userType = 'manager';
        autoBackupLog("Found manager user in session: {$current_user}", $debugMode);
    } 
    elseif (isset($_SESSION['webInternalKey']) && $_SESSION['webInternalKey'] > 0) {
        $current_user = $_SESSION['webInternalKey'];
        $userType = 'web';
        autoBackupLog("Found web user in session: {$current_user}", $debugMode);
    }
}

// If we have a user, get their information from database
if ($current_user > 0) {
    try {
        // Use direct database connection to get user info
        $database = EvolutionCMS()->getDatabase()->getConfig('database');
        $host = EvolutionCMS()->getDatabase()->getConfig('host');
        $db_username = EvolutionCMS()->getDatabase()->getConfig('username');
        $password = EvolutionCMS()->getDatabase()->getConfig('password');
        $prefix = EvolutionCMS()->getDatabase()->getConfig('prefix');
        
        $mysqli = new mysqli($host, $db_username, $password, $database);
        
        if (!$mysqli->connect_error) {
            // FIX: IMPOSTA IL CHARSET PER GESTIRE CORRETTAMENTE I CARATTERI SPECIALI
            $mysqli->set_charset('utf8mb4');
            autoBackupLog("Database connection established with utf8mb4 charset for user info", $debugMode);
            
            // Try different possible user tables for Evolution 3.x
            $possible_tables = [
                $prefix . 'users',           // Standard user table in Evolution 3.x  
                $prefix . 'active_users',    // Active users table
                $prefix . 'user_attributes', // User attributes
                $prefix . 'manager_users'    // Fallback for custom installations
            ];
            
            $user_found = false;
            foreach ($possible_tables as $table) {
                // Check if table exists before querying
                $check_table = $mysqli->query("SHOW TABLES LIKE '{$table}'");
                if ($check_table && $check_table->num_rows > 0) {
                    autoBackupLog("Table {$table} found, attempting user query...", $debugMode);
                    
                    $query = "SELECT username, role FROM {$table} WHERE id = " . intval($current_user);
                    $result = $mysqli->query($query);
                    
                    if ($result && $row = $result->fetch_assoc()) {
                        $username = $row['username'];
                        $current_role = $row['role'];
                        autoBackupLog("User info retrieved from {$table}: username={$username}, role={$current_role}", $debugMode);
                        $user_found = true;
                        break;
                    } else {
                        autoBackupLog("Table {$table}: no user with ID {$current_user}", $debugMode);
                    }
                } else {
                    autoBackupLog("Table {$table} does not exist", $debugMode);
                }
            }
            
            if (!$user_found) {
                autoBackupLog("WARNING: Unable to retrieve username, using 'admin'", $debugMode);
                $username = "admin";
            }
            
            $mysqli->close();
        } else {
            autoBackupLog("Connection error for user info retrieval: {$mysqli->connect_error}", $debugMode);
        }
    } catch (Exception $e) {
        autoBackupLog("Exception in user info retrieval: " . $e->getMessage(), $debugMode);
    }
}

autoBackupLog("Current user: ID={$current_user}, Role={$current_role}, Username={$username}, Type={$userType}", $debugMode);

// Permission check
switch ($allow_backup) {
    case 'ThisRolesOnly':
        $allowed_roles = array_map('trim', explode(',', $this_roles));
        $run_backup = in_array($current_role, $allowed_roles);
        break;
    case 'ThisUsersOnly':
        $allowed_users = array_map('trim', explode(',', $this_users));
        $run_backup = in_array($current_user, $allowed_users);
        break;
    default:
        $run_backup = false; // Security: default denies everything
        break;
}

if (!$run_backup) {
    autoBackupLog("Backup not executed: user {$current_user} with role {$current_role} does not meet criteria", $debugMode);
    return;
}

// Ensure path is absolute
if (!preg_match('~^(/|\\\\|[a-zA-Z]:)~', $backupPath)) {
    $backupPath = MODX_BASE_PATH . $backupPath;
}

// Ensure it ends with a slash
$backupPath = rtrim($backupPath, '/\\') . '/';
autoBackupLog("Backup path: {$backupPath}", $debugMode);

// Create directory if it doesn't exist
if (!is_dir($backupPath)) {
    if (!mkdir($backupPath, 0755, true)) {
        autoBackupLog("ERROR: Unable to create directory {$backupPath}", $debugMode);
        return;
    }
}

// Check write permissions
if (!is_writable($backupPath)) {
    autoBackupLog("ERROR: Backup directory is not writable: {$backupPath}", $debugMode);
    return;
}

// Create .htaccess to protect backups
if (!file_exists($backupPath . ".htaccess")) {
    $htaccess = "order deny,allow\ndeny from all\n";
    file_put_contents($backupPath . ".htaccess", $htaccess);
}

// Create backup filename - NEW FORMAT WITH DATE FIRST
$timestamp = date('Y-m-d_H-i-s');
$eventShort = str_replace(['On', 'User', 'Before', 'After'], '', $evtName);
$filename = "{$timestamp}_auto_snapshot_{$eventShort}_{$username}.sql";
$path = $backupPath . $filename;
autoBackupLog("Snapshot file: {$path}", $debugMode);

// Get database credentials from Evolution CMS 3.x
try {
    $database = EvolutionCMS()->getDatabase()->getConfig('database');
    $host = EvolutionCMS()->getDatabase()->getConfig('host');
    $db_username = EvolutionCMS()->getDatabase()->getConfig('username');
    $password = EvolutionCMS()->getDatabase()->getConfig('password');
    $prefix = EvolutionCMS()->getDatabase()->getConfig('prefix');
    $driver = EvolutionCMS()->getDatabase()->getConfig('driver');
    
    autoBackupLog("DB credentials: database={$database}, host={$host}, username={$db_username}, prefix={$prefix}, driver={$driver}", $debugMode);
    
    // Verify credentials
    if (empty($database) || empty($db_username)) {
        autoBackupLog("ERROR: Missing database credentials", $debugMode);
        return;
    }
    
    // DATABASE BACKUP - FORCED MANUAL METHOD WITH DESCRIPTION
    $backupSuccess = false;
    
    // ALWAYS FORCE MANUAL METHOD for complete control over header
    autoBackupLog("USING MANUAL METHOD for complete header and description control", $debugMode);
    
    try {
        // Get list of tables with specified prefix
        $sql = "SHOW TABLE STATUS FROM `{$database}` LIKE '{$prefix}%'";
        $rs = EvolutionCMS()->getDatabase()->query($sql);
        $tables = EvolutionCMS()->getDatabase()->getColumn('Name', $rs);
        
        autoBackupLog("Tables found: " . count($tables), $debugMode);
        if (count($tables) > 0) {
            autoBackupLog("First 3 tables: " . implode(", ", array_slice($tables, 0, 3)), $debugMode);
        }
        
        if (!empty($tables)) {
            @set_time_limit(300); // 5 minutes for backup
            
            // SQL file header for Evolution 3.x 
            $version = EvolutionCMS()->getVersionData();
            $siteName = EvolutionCMS()->getConfig('site_name');
            
            $output = "# " . addslashes($siteName) . " Database Dump\n";
            $output .= "# Evolution CMS Version: " . $version['version'] . "\n";
            $output .= "# \n";
            $output .= "# Host: " . $host . "\n";
            $output .= "# Generation Time: " . date("Y-m-d H:i:s") . "\n";
            $output .= "# Server version: " . EvolutionCMS()->getDatabase()->getVersion() . "\n";
            $output .= "# PHP Version: " . phpversion() . "\n";
            $output .= "# Database: " . $database . "\n";
            $output .= "# Description: Auto-snapshot triggered by {$username} via {$evtName}\n";
            $output .= "# CharSet Fix: utf8mb4 support enabled\n";
            $output .= "#\n";
            $output .= "# ------------------------------------------------------\n\n";
            
            $output .= "/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;\n";
            $output .= "/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;\n";
            $output .= "/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;\n";
            $output .= "/*!40101 SET NAMES utf8mb4 */;\n";
            $output .= "/*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;\n";
            $output .= "/*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;\n\n";
            
            // Write header to file
            $headerBytes = file_put_contents($path, $output);
            autoBackupLog("Header with description written: {$headerBytes} bytes", $debugMode);
            
            // Use direct mysqli for dump
            $mysqli = new mysqli($host, $db_username, $password, $database);
            if (!$mysqli->connect_error) {
                // FIX: IMPOSTA IL CHARSET PER GESTIRE CORRETTAMENTE I CARATTERI SPECIALI
                $mysqli->set_charset('utf8mb4');
                
                autoBackupLog("MySQL connection established for manual dump with utf8mb4 charset", $debugMode);
                
                // Loop through all tables
                $totalRows = 0;
                foreach ($tables as $table) {
                    autoBackupLog("Processing table: {$table}", $debugMode);
                    
                    // Get table structure
                    $result = $mysqli->query("SHOW CREATE TABLE `{$table}`");
                    if (!$result) {
                        autoBackupLog("ERROR in SHOW CREATE TABLE query: " . $mysqli->error, $debugMode);
                        continue;
                    }
                    
                    $row = $result->fetch_row();
                    $output = "DROP TABLE IF EXISTS `{$table}`;\n";
                    $output .= $row[1] . ";\n\n";
                    
                    // Write structure to file
                    file_put_contents($path, $output, FILE_APPEND);
                    
                    // Get table data
                    $result = $mysqli->query("SELECT * FROM `{$table}`");
                    if (!$result) {
                        autoBackupLog("ERROR in SELECT query: " . $mysqli->error, $debugMode);
                        continue;
                    }
                    
                    $numRows = $result->num_rows;
                    $totalRows += $numRows;
                    
                    if ($numRows > 0) {
                        autoBackupLog("Table {$table}: {$numRows} rows", $debugMode);
                        
                        // Process data row by row
                        while ($row = $result->fetch_row()) {
                            $output = "INSERT INTO `{$table}` VALUES (";
                            
                            $values = [];
                            foreach ($row as $value) {
                                if ($value === null) {
                                    $values[] = "NULL";
                                } else {
                                    $values[] = "'" . $mysqli->real_escape_string($value) . "'";
                                }
                            }
                            
                            $output .= implode(", ", $values);
                            $output .= ");\n";
                            
                            // Write each row to file
                            file_put_contents($path, $output, FILE_APPEND);
                        }
                        
                        file_put_contents($path, "\n", FILE_APPEND);
                    }
                }
                
                // Footer
                $output = "/*!40101 SET SQL_MODE=@OLD_SQL_MODE */;\n";
                $output .= "/*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;\n";
                $output .= "/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;\n";
                $output .= "/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;\n";
                $output .= "/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;\n";
                
                file_put_contents($path, $output, FILE_APPEND);
                
                // Verify if file exists and has reasonable size
                if (file_exists($path)) {
                    $filesize = filesize($path);
                    autoBackupLog("Manual backup with utf8mb4 charset completed: {$filesize} bytes, {$totalRows} total rows", $debugMode);
                    $backupSuccess = ($filesize > 500 && $totalRows > 0);
                }
                
                $mysqli->close();
            } else {
                autoBackupLog("ERROR mysqli connection for manual dump: {$mysqli->connect_error}", $debugMode);
            }
        } else {
            autoBackupLog("ERROR: No tables found", $debugMode);
        }
    } catch (Exception $e) {
        autoBackupLog("ERROR in manual dump method: " . $e->getMessage(), $debugMode);
    }
    
    // Final verification
    if ($backupSuccess) {
        // Log success
        autoBackupLog("SUCCESS: AutoSnapshot completed: {$filename} (" . filesize($path) . " bytes)", $debugMode);
        
        // Clean old backups
        $pattern = $backupPath . "*_auto_snapshot_*.sql";
        $files = glob($pattern);
        
        if (is_array($files) && count($files) > $keepBackups) {
            autoBackupLog("Cleaning old backups (keeping last {$keepBackups})...", $debugMode);
            
            // Sort by date (oldest first)
            usort($files, function($a, $b) {
                return filemtime($a) - filemtime($b);
            });
            
            // Delete the oldest
            $deleteCount = count($files) - $keepBackups;
            for ($i = 0; $i < $deleteCount; $i++) {
                if (@unlink($files[$i])) {
                    autoBackupLog("Backup deleted: " . basename($files[$i]), $debugMode);
                } else {
                    autoBackupLog("ERROR: unable to delete " . basename($files[$i]), $debugMode);
                }
            }
        }
    } else {
        autoBackupLog("ERROR: AutoSnapshot failed: unable to create database backup", $debugMode);
    }
    
} catch (Exception $e) {
    autoBackupLog("ERROR: AutoSnapshot exception: " . $e->getMessage(), $debugMode);
}

autoBackupLog("--- END AUTOSNAPSHOT 3.x ---", $debugMode);