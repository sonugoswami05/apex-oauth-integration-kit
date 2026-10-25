import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import LightningConfirm from 'lightning/confirm';
import getPayloadDiff from '@salesforce/apex/PayloadDiffController.getPayloadDiff';
import requestRegeneration from '@salesforce/apex/PayloadDiffController.requestRegeneration';

const KIND_META = {
    changed: { label: 'Changed', iconName: 'utility:edit', chipClass: 'chip chip_changed' },
    added: { label: 'Added', iconName: 'utility:add', chipClass: 'chip chip_added' },
    removed: { label: 'Removed', iconName: 'utility:dash', chipClass: 'chip chip_removed' }
};

const NOTICES = {
    NO_BASELINE: {
        variant: 'info',
        iconName: 'utility:info',
        fallback: 'This request has not been generated yet.'
    },
    IDENTICAL: {
        variant: 'success',
        iconName: 'utility:success',
        fallback: 'No changes since the last generation.'
    },
    SCHEMA_MISMATCH: {
        variant: 'warning',
        iconName: 'utility:warning',
        fallback: 'The payload format changed, so a field-level comparison is not available.'
    },
    INVALID_PAYLOAD: {
        variant: 'error',
        iconName: 'utility:error',
        fallback: 'The current payload is not valid JSON.'
    }
};

const EMPTY_VALUE = '(none)';

function reduceError(error) {
    if (!error) {
        return 'Unknown error';
    }
    if (Array.isArray(error.body)) {
        return error.body.map((entry) => entry.message).join(', ');
    }
    return error.body?.message ?? error.message ?? 'Unknown error';
}

function plural(count, word) {
    return `${count} ${word}${count === 1 ? '' : 's'}`;
}

export default class PayloadDiffViewer extends LightningElement {
    @api recordId;

    diff;
    error;
    activeFilter = 'all';
    isSubmitting = false;
    wiredDiffResult;

    @wire(getPayloadDiff, { requestId: '$recordId' })
    wiredDiff(result) {
        this.wiredDiffResult = result;
        const { data, error } = result;
        if (data) {
            this.diff = data;
            this.error = undefined;
        } else if (error) {
            this.error = reduceError(error);
            this.diff = undefined;
        }
    }

    get isLoading() {
        return !this.diff && !this.error;
    }

    get totalChanges() {
        if (!this.diff) {
            return 0;
        }
        return this.diff.changedCount + this.diff.addedCount + this.diff.removedCount;
    }

    get hasChanges() {
        return this.diff?.status === 'CHANGED' && this.totalChanges > 0;
    }

    get summaryText() {
        if (!this.diff) {
            return '';
        }
        if (this.diff.status !== 'CHANGED') {
            return this.diff.baselineName
                ? `Compared with snapshot ${this.diff.baselineName} (schema v${this.diff.baselineSchemaVersion}).`
                : 'No earlier snapshot to compare with.';
        }
        const capturedOn = this.diff.baselineCapturedOn ? new Date(this.diff.baselineCapturedOn).toLocaleString() : 'an earlier run';
        return `${plural(this.totalChanges, 'change')} since snapshot ${this.diff.baselineName}, captured ${capturedOn}.`;
    }

    get notice() {
        const meta = this.diff ? NOTICES[this.diff.status] : undefined;
        if (!meta) {
            return undefined;
        }
        return {
            className: `slds-scoped-notification slds-scoped-notification_light slds-media slds-media_center notice notice_${meta.variant}`,
            iconName: meta.iconName,
            message: this.diff.message || meta.fallback
        };
    }

    get changedBadgeLabel() {
        return `${this.diff.changedCount} changed`;
    }

    get addedBadgeLabel() {
        return `${this.diff.addedCount} added`;
    }

    get removedBadgeLabel() {
        return `${this.diff.removedCount} removed`;
    }

    get filterOptions() {
        return [
            { label: `All (${this.totalChanges})`, value: 'all' },
            { label: `Changed (${this.diff.changedCount})`, value: 'changed' },
            { label: `Added (${this.diff.addedCount})`, value: 'added' },
            { label: `Removed (${this.diff.removedCount})`, value: 'removed' }
        ];
    }

    get visibleRows() {
        const rows = this.diff?.rows ?? [];
        return rows
            .filter((row) => this.activeFilter === 'all' || row.kind === this.activeFilter)
            .map((row) => {
                const meta = KIND_META[row.kind] ?? KIND_META.changed;
                const hasOld = row.kind !== 'added';
                const hasNew = row.kind !== 'removed';
                return {
                    ...row,
                    kindLabel: meta.label,
                    iconName: meta.iconName,
                    chipClass: meta.chipClass,
                    rowClass: `row row_${row.kind}`,
                    typeNote: row.typeChanged ? `Type: ${row.oldType} to ${row.newType}` : null,
                    beforeText: hasOld ? row.oldValue : EMPTY_VALUE,
                    afterText: hasNew ? row.newValue : EMPTY_VALUE,
                    beforeClass: hasOld ? 'value value_old' : 'value value_empty',
                    afterClass: hasNew ? 'value value_new' : 'value value_empty'
                };
            });
    }

    get shownRowCount() {
        return this.diff?.rows?.length ?? 0;
    }

    get regenerateLabel() {
        return this.diff?.status === 'NO_BASELINE' ? 'Generate document' : 'Regenerate document';
    }

    get regenerateDisabled() {
        return this.isSubmitting || !this.diff?.canRegenerate;
    }

    get confirmMessage() {
        switch (this.diff?.status) {
            case 'CHANGED':
                return `${plural(this.totalChanges, 'change')} will be sent to the document provider. Continue?`;
            case 'IDENTICAL':
                return 'Nothing changed since the last generation. Generate the document again anyway?';
            case 'SCHEMA_MISMATCH':
                return `The payload format changed from v${this.diff.baselineSchemaVersion} to v${this.diff.currentSchemaVersion}. Review the new document carefully once it is ready. Continue?`;
            default:
                return 'Send this payload to the document provider?';
        }
    }

    handleFilterChange(event) {
        this.activeFilter = event.detail.value;
    }

    handleRefresh() {
        return refreshApex(this.wiredDiffResult);
    }

    async handleRegenerate() {
        const confirmed = await LightningConfirm.open({
            label: this.regenerateLabel,
            message: this.confirmMessage,
            theme: this.diff?.status === 'SCHEMA_MISMATCH' ? 'warning' : 'default'
        });
        if (!confirmed) {
            return;
        }
        this.isSubmitting = true;
        try {
            await requestRegeneration({ requestId: this.recordId });
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Generation started',
                    message: 'The request is queued. Its status moves to Complete when the provider finishes.',
                    variant: 'success'
                })
            );
            await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
            await refreshApex(this.wiredDiffResult);
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Generation could not start',
                    message: reduceError(error),
                    variant: 'error'
                })
            );
        } finally {
            this.isSubmitting = false;
        }
    }
}
