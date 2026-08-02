export interface FileItem {
  id: number;
  name: string;
  mime: string;
  size_bytes: number;
  uploader_id: number;
  created_at: number;
}

export interface FileListResult {
  list: FileItem[];
  total: number;
  page: number;
  pageSize: number;
}
