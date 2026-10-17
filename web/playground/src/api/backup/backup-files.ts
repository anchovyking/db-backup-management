import { requestClient } from '#/api/request';

export namespace BackupFilesApi {
  export interface BackupFile {
    backup_file_id?: string;
    backup_type?: 'full' | 'increment';
    backupDir: string;
    backupTime: string;
    binlog_end_file?: string;
    binlog_end_pos?: number;
    binlog_start_file?: string;
    binlog_start_pos?: number;
    database: string;
    db_instance_id?: string;
    dirName: string;
    full_backup_file_id?: string;
    job_id?: string;
    size: number;
  }

  /** mydumper metadata 解析出的表或视图 */
  export interface BackupObjectItem {
    kind: 'table' | 'view';
    name: string;
    real_table_name: string;
    rows: number;
    schema: string;
  }

  export interface BackupLogsDetail {
    backupDir: string;
    backupLog: string;
    backupLogPresent: boolean;
    database: string;
    dirName: string;
    restoreLog: string;
    restoreLogPresent: boolean;
  }

  export interface BackupTablesDetail {
    backupDir: string;
    database: string;
    dirName: string;
    items: BackupObjectItem[];
    /** metadata=解析 metadata 文件；filenames=无完整 metadata 时由 data 下 .sql.zst 文件名推断 */
    itemsSource?: 'filenames' | 'metadata';
    table_count: number;
    tables: BackupObjectItem[];
    view_count: number;
    views: BackupObjectItem[];
  }

  /** 批量删除的单条结果 */
  export interface BackupDeleteItemResult {
    dirName: string;
    error?: string;
    removed_disk?: boolean;
    resolved_path?: string;
  }

  export interface BackupBatchDeleteResult {
    /** 实际删除成功的条目（含级联删除的增量） */
    cascaded: string[];
    deleted: BackupDeleteItemResult[];
    /** 删除失败的条目；单条失败不影响其余条目 */
    failed: BackupDeleteItemResult[];
    /** 去重归一化后的请求条目数 */
    requested: number;
  }
}

async function getBackupFilesList(keyword?: string) {
  return requestClient.get<BackupFilesApi.BackupFile[]>('/backup-files', {
    params: { keyword },
  });
}

async function deleteBackupFile(dirName: string) {
  return requestClient.delete(`/backup-files/${encodeURIComponent(dirName)}`);
}

/**
 * 批量删除备份记录。
 * @param dirNames 目录名数组（后端去重归一化）
 * @param cascade 删除全量备份时是否连带删除其关联增量，默认 true
 */
async function batchDeleteBackupFiles(
  dirNames: string[],
  cascade = true,
) {
  return requestClient.post<BackupFilesApi.BackupBatchDeleteResult>(
    '/backup-files/batch-delete',
    { cascade, dirNames },
  );
}

/** 下载该条记录 backupDir 目录打包的 tar.gz */
async function downloadBackupArchive(dirName: string) {
  return requestClient.download<Blob>(
    `/backup-files/${encodeURIComponent(dirName)}/download`,
    // 下载文件可能需要明显超过默认 10s（打包 tar.gz + 传输）。
    // 显式放大 timeout，避免点击无响应/被 axios 超时中断。
    { timeout: 0 },
  );
}

/** 解析该备份 metadata，列出包含的表与视图 */
async function getBackupFileTables(dirName: string) {
  return requestClient.get<BackupFilesApi.BackupTablesDetail>(
    `/backup-files/${encodeURIComponent(dirName)}/tables`,
  );
}

async function getBackupFileLogs(dirName: string) {
  return requestClient.get<BackupFilesApi.BackupLogsDetail>(
    `/backup-files/${encodeURIComponent(dirName)}/logs`,
  );
}

export {
  batchDeleteBackupFiles,
  deleteBackupFile,
  downloadBackupArchive,
  getBackupFileLogs,
  getBackupFilesList,
  getBackupFileTables,
};
